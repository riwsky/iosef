# Performance hot paths + correctness evals — per-item design

Companion to [perf-and-evals-roadmap.md](perf-and-evals-roadmap.md): research verdicts with sources, and detailed designs (function signatures, spike steps, check-by-check details) for each roadmap item.

## Research verdicts (done first — they reshape the plan)

### P2 — Single-request tree snapshot: **the multi-attribute request is real and confirmed**

Decompiled `AccessibilityPlatformTranslation` (iOS 17.6 + iOS 26.1 restores, headers from iOS 18.2 dyld cache) shows the XPC wire protocol iosef already speaks has an untapped bulk path:

- `AXPTranslatorRequest` fields: `translation`, `requestType`, `attributeType`, `actionType`, `parameters` (NSDictionary), `clientType` — all settable, `NSSecureCoding`.
- `processTranslatorRequest:` dispatch table (device side): **1**=applicationObject, **2**=attribute, **3**=canSetAttribute, **4**=frontMostApp, **5**=**multipleAttribute**, **6**=hitTest, **7**=action, **8**=setAttribute, **9**=supportedActions, **10**=supportsAttributes.
- `processMultipleAttributeRequest:` (device side) reads `parameters[@"attributes"]` = array of NSNumbers (AXP attribute codes), maps them to native AX attributes, and services them with **one** `AXUIElementCopyMultipleAttributeValues` call, returning a dictionary keyed by the requested codes in `response.resultData`.
- `frontmostApplicationWithDisplayId:` is itself just requestType 4 with `parameters = {"displayId": n}` → `response.translationResponse`.

**Consequence:** iosef can build `AXPTranslatorRequest` objects directly and send them via the existing `sendAccessibilityRequest(_:toDevice:)`, bypassing `AXPMacPlatformElement`'s lazy one-attribute-per-XPC accessors entirely. Per element: 1 XPC for {role, label, title, value, identifier, help, frame, traits, children} instead of ~9. A 200-element tree drops from ~1800 to ~200 XPC round-trips. And because we build requests ourselves (no shared AXPTranslator singleton state, no token delegate in the request path), **pipelining sibling fetches concurrently becomes our own code's concern — P3's translator thread-safety question evaporates.**

There is also a **tree-dump cache** subsystem (iOS 18+): `requestResolvingBehavior` = 1|2 makes `frontmostApplicationWithDisplayId:` serve from `bridgeDelegateTokenToTreeDumpLookup`; device side generates dumps (`generateAXTreeDumpTypeOnBackgroundThread`, `AXPTreeDumpTypeInitialDump`/`AdditionalData`/`TreeDestroyed`) and pushes them to the host via `handleUpdatedAXTree:` — but that requires a host-side notification channel registration we don't have plumbed. Verdict: **optional later spike**, only if bulk+pipelined isn't enough.

- **xctree** (ldomaradzki): uses the *public macOS AX API* against Simulator.app's window; requires macOS Accessibility permissions — contradicts iosef's zero-permission design. Dead end (though it validates the multi-attribute idea: public `AXUIElementCopyMultipleAttributeValues` is exactly what the sim-side handler calls).
- **WDA / XCTest `snapshotWithAttributes`**: genuinely one call for the whole tree via testmanagerd, but needs an XCUITest runner app installed + a test session; Appium's own docs describe it as time-expensive with testmanagerd snapshot timeouts on large hierarchies, mitigated by depth limits and attribute exclusion. Adopting that stack = new heavyweight dependency, session boot latency, Xcode-version fragility. **Dead end for iosef.**
- **testa** (valewnrt/testa), closest competitor: same per-attribute AXP pattern + warm daemon, claims ~60ms/snapshot warm — evidence for P7's upside, and a bar to beat with P2a.
- **SimPilot** docs note AXPTranslator pins the cached frontmost `AXPMacPlatformElement` to the *first* token — a real hazard for the legacy path if we ever reuse bridges across tokens concurrently; direct requests sidestep it.

### P5 — Pasteboard fast-path: **validated, with known precedent and caveats**

`lycorp-jp/sim-use` ships exactly this: `simctl pbcopy` + HID Cmd-V, noting (a) Cmd-V requires the simulator's hardware-keyboard mode (Simulator.app I/O ▸ Keyboard ▸ Connect Hardware Keyboard), (b) under soft-keyboard-only mode HID Cmd-V is dropped, their fallback is long-press + edit-menu "Paste". Also: Xcode 26.4 had a broken sim-paste regression (fixed in 26.5) — worth a runtime sanity check rather than blind trust. iosef already sends raw HID keyboard events successfully, so the Cmd chord (0xE3 down, 0x19 'V' down/up, 0xE3 up) rides the same path. This also fixes a real correctness bug: `typeText` silently drops all non-ASCII characters today.

### P3 — Parallel XPC through AXPTranslator: **cut as framed; folded into P2a**

Walking sibling subtrees concurrently through the AXPTranslator singleton + `AXPMacPlatformElement` lazy accessors is not worth the risk: the singleton holds mutable caches (`fakeElementCache`, token→tree-dump maps), and SimPilot's token-pinning observation shows internal state is token-coupled. Instead, P2a phase 2 pipelines *self-built* requests over `sendAccessibilityRequestAsync` (bounded in-flight window). The device may serialize XPC service-side, but the host stops paying one full round-trip of dead time per attribute.

---

## Per-item design

### 1. E4 — Perf instrumentation (S)

New `Sources/SimulatorKit/PerfStats.swift`: a `final class PerfStats: @unchecked Sendable` with `NSLock`-guarded counters and a task-local/explicit instance (simplest: process-global with reset per op).

```swift
public final class PerfStats: @unchecked Sendable {
    public static let shared = PerfStats()
    public var enabled: Bool  // ProcessInfo IOSEF_PERF == "1"
    public func increment(_ counter: Counter)          // .xpcAccessibility, .xpcHID, .hitTest
    public func recordPhase(_ name: String, ms: Double)
    public func snapshotAndReset() -> [String: Double]
}
```

Hook points: `PrivateFrameworkBridge.sendAccessibilityRequest` (PrivateFrameworkBridge.swift:530), `PrivateFrameworkBridge.sendMessage` (:576), `AXPAccessibilityBridge.hitTestNode`. Emission: wrap `handleToolCall` — after each op, if enabled, `FileHandle.standardError.write` one JSON line: `{"iosef_perf":{"op":"describe","xpc_ax":412,"xpc_hid":0,"hit_tests":36,"elements":198,"wall_ms":842}}`. The existing `logDiagnostic("accessibility: N elements in Xms")` already proves stderr is the right channel; harnesses regex for `"iosef_perf"`.

Verify (Mac): `IOSEF_PERF=1 iosef describe 2>&1 >/dev/null | grep iosef_perf`; count matches expectation (~9×elements before P2a, ~1×elements after).

### 2. E1 — Deterministic correctness suite (M)

New `scripts/correctness.py` (uv inline-deps script, click — same style as benchmark.py). No committed-latency flakiness: correctness assertions committed; latency baselines per-machine.

Checks (each returns `{name, status: pass|fail|xfail|xpass, ms, perf: {...}, details}`):
- `describe_grid`: all 48 `grid_R_C` identifiers present (8×6 per GridSection.swift), frames non-zero, row/col frame ordering monotonic.
- `tap_increment`: `tap --identifier grid_3_4` ×3 → `text --identifier tap_count_label` == "3"; `last_tap_label` matches.
- `type_ascii`: `type --identifier text_field --text "hello world 42!"` → `text` readback equals input; `log_show --process MCPTestApp` contains `[MCPTest] Text changed`.
- `type_nonascii` (**xfail today**): `"héllo — 世界 🚀"` readback. Flips to pass with P5.
- `swipe_direction`: describe `swipe_area` frame → rightward swipe within it → `text --identifier swipe_status_label` indicates right.
- `navbar_regression` (issue #2): `tap --identifier open_detail` → `wait --identifier detail_content` → describe contains nav-bar children (back button).
- `describe_point`: center of `grid_0_0` frame → `describe --x --y` returns that identifier.
- `wait_latency`: `wait --identifier grid_0_0` on already-present element (measures poll fast path).
- `--watch` flag: 5×4 grid variant against WatchTestApp.

Flow: resolve/boot sim (reuse `scripts/build-test-app.sh` to build+install), launch via `iosef launch_app --terminate_running`, run checks serially, write `results/correctness-<ts>.jsonl` + `summary.md` table. `--baseline <file>`: exit 1 on any correctness regression; latency compared as median-of-N vs baseline with `--latency-threshold 25%` (warn by default, `--strict-latency` to fail). `--update-baseline` writes `.iosef-baselines/correctness.json` (gitignored) and there's a committed structural expectations file `scripts/expectations/mcptestapp.json` (the 48 ids, labels, etc.).

Every check runs with `IOSEF_PERF=1` and records XPC counts — so "describe now costs 210 XPC calls, was 1830" is a first-class regression metric.

### 3. P6 — Micro wins (S)

- **Shared completion queue**: PrivateFrameworkBridge.swift:543 allocates a `DispatchQueue` per XPC call. Make it `private static let axCallbackQueue = DispatchQueue(label: "iosef.ax.callback")` (serial is fine — the caller blocks on the group anyway). Same for `sendMessage`'s per-call semaphore queue use (already global — fine).
- **Lazy VCS spawn**: `setupGlobals()` (CLICommands.swift:58) runs `jj root` + `git rev-parse` subprocess on every CLI invocation. Change `SimCtlClient.defaultDeviceName: String?` to `SimCtlClient.defaultDeviceNameProvider: (() -> String?)?` evaluated (once, memoized) only inside `resolveDevice(nil)` when no explicit identifier, no session state, no cache. Explicit `--device` and session-state runs never pay the ~20-80ms spawn.
- **Traversal-level depth**: `handleDescribe` (ToolHandlers.swift:39) fetches the FULL tree then truncates in `TreeSerializer.toMarkdown(nodes, maxDepth:)`. Pass `depth` into the walk (becomes `TraversalPlan.maxDepth` in P1) so `describe --depth 3` stops fetching XPC at depth 3.
- **Swipe step batching (flagged, behind env)**: `sendMessage` waits on a completion semaphore per drag step (~20 waits/swipe). Fire-and-forget intermediate drag events, block only on the final up message. Gate behind `IOSEF_SWIPE_PIPELINE=1` until E1's swipe check proves it reliable.

### 4. P1 — Selector-aware traversal (M)

New type in `Sources/SimulatorKit/Accessibility/` (TraversalPlan.swift):

```swift
public struct TraversalPlan: Sendable {
    public enum Projection: Sendable { case full, selectorMatch }
    public var projection: Projection = .full
    public var selector: AXSelector? = nil       // evaluated during the walk
    public var stopAfterFirstMatch: Bool = false
    public var maxDepth: Int? = nil
    public var expandEmptyContainers: Bool = true // hit-test fallbacks
    public static let fullTree = TraversalPlan()
}

public struct TraversalOutcome: Sendable {
    public let roots: [TreeNode]      // projected tree (full projection only)
    public let matches: [TreeNode]    // fully-populated matched nodes, frames in iOS points
    public let truncated: Bool        // stopAfterFirstMatch fired
}
```

`AXPAccessibilityBridge.accessibilityElements(plan:timeout:)` replaces the internals of `accessibilityElements()` (kept as a `.fullTree` wrapper). `serializeElement` changes:

1. Under `.selectorMatch`, fetch only role/label/title/identifier (4 XPC), evaluate `selector.matches(partialNode)` — `AXSelector.matches` (AXSelector.swift:25) only reads those four fields, so matching on a partial node is sound.
2. On match: fetch value/frame/help/traits for that node only (+4 XPC), transform its frame with `cachedRootFrame` (AXPAccessibilityBridge.swift:25 — already cached from the root fetch, no extra XPC), append to matches; if `stopAfterFirstMatch`, unwind via a private `struct EarlyExit: Error` sentinel caught in `accessibilityElements(plan:)`.
3. `maxDepth` honored during the walk.
4. Skip `expandEmptyContainers`/grid-scan under selectorMatch **unless zero matches at the end** — then run one fallback full walk with hit-testing (preserves issue #2: a selector targeting a nav-bar child still resolves, just on the slow path). Second pass only when the fast pass found nothing.

Callers, in `Sources/iosef/Schemas.swift` — `resolveSelector` grows a mode:
```swift
func resolveSelector(from params: CallTool.Parameters, firstMatchOnly: Bool = false) async throws
    -> (selector: AXSelector, matches: [TreeNode])
```
- `exists`, `text`, `tap`/`type`-by-selector (`resolveAndTapFirstMatch`), `wait` poll → `firstMatchOnly: true`.
- `count`, `find` → full scan but `.selectorMatch` projection (still ~4-5 XPC/element instead of 9, no hit-test sweeps).
- `wait` (ToolHandlers.swift:241): each 250ms poll now early-exits; on success returns the fully-populated match as today.

Expected effect (measured by E4): `exists` matching element #30 of 200: ~1800 → ~130 XPC. Misses: ~1800 → ~1000 (projection only). Combined with P2a, a hit becomes ~30 XPC.

### 5. P2a — Direct multi-attribute requests (M spike + M productionize)

**Spike (day 1-2, on the Mac):**
1. Attribute-code discovery: temporarily log every `AXPTranslatorRequest` passing through `AXPTranslationDispatcher.accessibilityTranslationDelegateBridgeCallbackWithToken` (`request.description` prints e.g. `attribute: AXPAttributeChildren` — seen in idb issue #802), while touching each accessor on a known element. Record the numeric `attributeType` for role/label/title/value/identifier/help/frame/traits/children.
2. Build requestType 5 by hand: `AXPTranslatorRequest.requestWithTranslation(translation)`, `setRequestType: 5`, `setParameters: ["attributes": codes.map(NSNumber.init)]`, send via existing `sendAccessibilityRequest`; dump `response.resultData` types. Determine: frame value encoding (NSValue rect vs dict), children encoding (array of `AXPTranslationObject`? of `remoteTranslationData`? — feed through `translationObjectFromData:` if needed), and coordinate space (direct responses may already be iOS points, since the macOS letterbox transform lives in `AXPMacPlatformElement`; if so the uniform-scale transform shrinks or disappears for this engine).
3. Also build requestType 4 (frontMostApp, `{"displayId": 0}`) and 6 (hitTest) directly — if all three work, describe/selector paths never touch the AXPTranslator singleton at all (no token delegate, no macPlatformElement, no SimPilot token-pinning hazard). dlopen of AXP is still needed for the request/response/translation classes.

**Productionize:** new `Sources/SimulatorKit/Accessibility/AXPDirectRequestEngine.swift`:

```swift
enum AXPAttributeCode: UInt64 { case role = ..., label = ..., ... }  // values from spike, names asserted against description strings at init
final class AXPDirectRequestEngine {
    init(device: AnyObject, bridge: PrivateFrameworkBridge) throws  // verifies classes + one probe request
    func frontmostTranslation(displayId: UInt32) throws -> AnyObject
    func fetchAttributes(_ codes: [AXPAttributeCode], translation: AnyObject, timeout: Double) throws -> [AXPAttributeCode: Any]
    func serializeTree(plan: TraversalPlan, deadline: ContinuousClock.Instant) throws -> TraversalOutcome
}
```

`AXPAccessibilityBridge` selects engine via `IOSEF_AX_ENGINE=legacy|direct` (default `legacy` until E1 shows parity on iOS 17/18/26 sims, then flip to `direct` with automatic fallback to legacy on engine-init failure — old Xcode versions may predate requestType 5, though it exists at least since iOS 14 headers).

**Phase 2 — pipelining (folded P3):** in `serializeTree`, after fetching a node's children translations, issue the children's `fetchAttributes` calls concurrently via `sendAccessibilityRequestAsync` completions (a small `DispatchGroup` + bounded window of ~8 in flight; results ordered by index). No shared translator state involved. Guarded by `IOSEF_AX_PIPELINE` initially; E1 tree-equality check is the gate. Even if the sim serializes server-side, host round-trip dead time collapses.

Risks: attribute code renumbering across OS versions (mitigate: runtime assertion via `request.description` naming, fallback engine), value decoding differences per element kind (E1 covers text field/toggle/slider/buttons), traits fetch (`AXTraits` today goes through `accessibilityAttributeValue:` — spike must find its AXP code; worst case keep per-element traits on the legacy accessor for matched/full nodes only).

### 6. P5 — Pasteboard type fast-path (S/M)

- `IndigoHIDClient.pasteChord()`: keyCode 0xE3 (LeftGUI) down → 0x19 ('v') down/up → 0xE3 up, reusing `sendKeyEvent`.
- `handleType` (ToolHandlers.swift:48): decision `shouldPaste(text) = !text.allSatisfy(\.isASCII) || text.count >= 20` overridable by `IOSEF_TYPE_MODE=auto|keys|paste` and a `--paste/--no-paste` CLI flag + MCP param.
- Paste path: `SimCtlClient.run("xcrun", ["simctl", "pbcopy", udid])` feeding text on stdin (needs a stdin-capable variant of `SimCtlClient.run`), small settle (~50ms, calibrated by P4), then `pasteChord()`.
- Non-ASCII in `keys` mode stops being silently dropped: if `hidKeyCode(for:)` returns nil for any char and mode is `keys`, either auto-upgrade to paste (auto mode) or return an error naming the unsupported characters.
- Caveats documented: requires hardware-keyboard mode; E1 `type_nonascii` is the oracle (flips xfail→pass). If Cmd-V proves flaky in some Simulator configs, sim-use's edit-menu fallback (long-press + tap "Paste" via selector) is the documented escape hatch — do not build it until the simple path demonstrably fails.

### 7. P4 — Timing calibration (M)

`scripts/calibrate.py` (python/uv, same conventions; lives next to benchmark.py; imports shared helpers — extract `scripts/_iosef_harness.py` used by both correctness.py and calibrate.py for sim setup/oracle readback).

Swift side first: replace magic constants with env-tunable `Tunables` (new `Sources/SimulatorKit/Tunables.swift`, read once):
- `IOSEF_TAP_HOLD_MS` (30, IndigoHIDClient.swift:42), `IOSEF_KEY_DELAY_MS` (10, :118), `IOSEF_KEYBOARD_SETTLE_MS` (100, ToolHandlers.swift:60), `IOSEF_SWIPE_STEP_DELAY_MS` (10, IndigoHIDClient.swift:68), `IOSEF_WAIT_POLL_MS` (250, ToolHandlers.swift:257), `IOSEF_PASTE_SETTLE_MS` (P5).

Calibration per constant: binary search over value with `trial(value) -> bool` = N=20 repetitions of the oracle op, all must pass (tap→tap_count_label delta; type→text_field readback; swipe→swipe_status_label). Result = smallest passing value × 1.5 safety margin. Output JSONL + suggested-defaults table; owner reviews and commits new defaults manually (calibration is machine/SoC dependent — never auto-commit). Reset app state between trials (relaunch with `terminate_running`).

### 8. E3 — Token-efficiency metrics (S)

benchmark.py: new `tokens` subcommand/mode. For a fixed MCPTestApp screen: capture describe output from (a) iosef markdown, (b) iosef `--json`, (c) `idb ui describe-all --json`, (d) node ios-simulator-mcp describe. Report bytes + approx tokens (`len/4`, optional tiktoken if installed) in the same comparison-table style. Store alongside latency results in the E1 results dir so regressions in verbosity are visible.

### 9. E2 — Agent-eval runner (M/L)

`skills/ios-simulator-interaction-workspace/evals/run_evals.py` (workspace .gitignore already anticipates `iteration-*/` + `skill-snapshot/`).

Per eval case from evals.json:
1. Fresh `iteration-N/case-<id>/` dir; snapshot the skill into `skill-snapshot/`; reset sim + MCPTestApp state.
2. Run `claude -p "<prompt>" --output-format stream-json --max-turns 30` with the skill available and cwd = repo (needs `scripts/build-test-app.sh` reachable). Capture full stream → transcript.jsonl (gives tool-call count, tokens, cost, wall time).
3. Grade in two layers:
   - **Programmatic**: post-hoc app-state checks per case (case 1: tap_count==1 via `iosef text`; case 2: log contains `[MCPTest] Text changed`; case 4: swipe_status_label direction) + transcript greps (`--help` not invoked; selector flags present in Bash tool calls).
   - **LLM judge**: one `claude -p` call with transcript + the case's `expectations[]`, returning strict JSON `{expectation, verdict, evidence}` per item.
4. Emit `results.jsonl` (one line per case: success, expectation pass ratio, tool_calls, tokens_in/out, wall_s) + `summary.md`. `--case N` to run one, `--iterations K` for repeatability stats. Serial execution, one simulator, no hosted tracking — everything local files.

### Deferred

- **P2b tree-dump cache**: revisit only if direct+pipelined describe still >300ms on big trees. Spike shape: set `requestResolvingBehavior=2` via KVC, find how `handleUpdatedAXTree:` is fed (likely a SimDevice accessibility-notification registration Simulator.app performs), confirm dumps arrive per-token. High reverse-engineering cost; iOS 18+ only.
- **P7 CLI daemon**: `iosef daemon --socket ~/.iosef/daemon.sock` reusing `handleToolCall` over JSON-lines; CLI subcommands auto-connect when socket present, spawn-on-demand with 5-min idle exit, build-hash handshake (restart on mismatch). testa's ~60ms warm snapshots show the ceiling. Defer: MCP mode already amortizes for agent use; revisit if CLI-mode agent workflows (bash scripts in skills) dominate.

## What was cut outright

- P3 as originally framed (concurrent walks through AXPTranslator/AXPMacPlatformElement) — superseded by direct-request pipelining.
- XCTest/WDA/testmanagerd migration — wrong stack for iosef.
- xctree-style public AX API — permission requirement kills it.
- Any hosted tracking — everything lands as JSONL + markdown in-repo/`results/`.

## Sources

[xctree](https://github.com/ldomaradzki/xctree) · [testa](https://github.com/valewnrt/testa) · [iOS 18.2 AXP headers (userlandkernel)](https://github.com/userlandkernel/ios17-dyld-headers) · [decompiled AXPTranslator iOS 17.6](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore) · [decompiled AXPTranslator_iOS iOS 26.1](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore) · [idb issue #802 (request logging)](https://github.com/facebook/idb/issues/802) · [AXe clientType patch](https://github.com/cameroncooke/AXe) · [SimPilot private-symbols notes](https://github.com/hmhv/SimPilot) · [baguette accessibility docs](https://github.com/tddworks/baguette) · [sim-use paste design](https://github.com/lycorp-jp/sim-use) · [Appium WDA slowness guide](https://appium.github.io/appium-xcuitest-driver/latest/troubleshooting/wda-slowness/) · [WDA snapshot refactor PR #407](https://github.com/appium/WebDriverAgent/pull/407) · [Xcode 26.4 paste regression](https://samwize.com/2026/03/30/xcode-simulator-paste-broken-workaround/) · [nst/iOS-Runtime-Headers AXPTranslator.h](https://github.com/nst/iOS-Runtime-Headers)
