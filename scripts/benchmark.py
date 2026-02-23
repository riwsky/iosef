#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["click"]
# ///
"""Benchmark Swift MCP vs Node MCP (mcp mode) and/or Swift CLI vs idb (cli mode)."""

import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import click

SWIFT_BIN_DEFAULT = ".build/release/iosef"
NODE_SERVER_DEFAULT = "node ../ios-simulator-mcp/build/index.js"
IDB_DEFAULT = "../idb"
RESULTS_DIR = Path("/tmp/ios-sim-mcp-bench")
BASELINE_WORKSPACE_DIR = Path("/tmp/ios-sim-mcp-bench-baseline")
BASELINE_WORKSPACE_NAME = "bench-baseline"

# MCP-level benchmark tools: (tool_name, extra_params_or_None)
TOOLS: list[tuple[str, dict | None]] = [
    ("get_booted_sim_id", None),
    ("describe_all", None),
    ("describe_point", {"x": 165, "y": 269}),
    ("tap", {"x": 165, "y": 269}),
    ("view", None),
]

# CLI-level benchmark tools: (display_name, swift_cli_template, baseline_template, baseline_label)
# Templates use {udid}, {swift_bin}, {idb} placeholders.
CLI_TOOLS: list[tuple[str, str, str, str]] = [
    (
        "describe_all",
        "{swift_bin} describe_all --udid {udid}",
        "{idb} ui describe-all --udid {udid} --json",
        "idb",
    ),
    (
        "describe_point",
        "{swift_bin} describe_point --x 165 --y 269 --udid {udid}",
        "{idb} ui describe-point --udid {udid} --json -- 165 269",
        "idb",
    ),
    (
        "tap",
        "{swift_bin} tap --x 165 --y 269 --udid {udid}",
        "{idb} ui tap --udid {udid} --json -- 165 269",
        "idb",
    ),
    (
        "screenshot",
        "{swift_bin} view --udid {udid}",
        "xcrun simctl io {udid} screenshot --type=png /tmp/bench_ss.png",
        "simctl",
    ),
]


def info(msg: str) -> None:
    click.echo(click.style("==> ", fg="green", bold=True) + click.style(msg, bold=True))


def warn(msg: str) -> None:
    click.echo(click.style("warning: ", fg="yellow", bold=True) + msg)


def error(msg: str) -> None:
    click.echo(click.style("error: ", fg="red", bold=True) + msg, err=True)


def run(cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)


# --- jj baseline helpers ---


def resolve_jj_revision(rev: str) -> tuple[str, str]:
    """Resolve a jj revision specifier to (change_id, first_line_of_description).

    Exits on failure.
    """
    r = run(f"jj log -r '{rev}' --no-graph -T 'change_id ++ \"\\n\" ++ description.first_line()'")
    if r.returncode != 0:
        error(f"Failed to resolve jj revision '{rev}': {r.stderr.strip()}")
        sys.exit(1)
    lines = r.stdout.strip().split("\n", 1)
    change_id = lines[0].strip()
    description = lines[1].strip() if len(lines) > 1 and lines[1].strip() else "(no description)"
    return change_id, description


def _swift_build(label: str, cwd: Path | None = None, *, verbose: bool = False) -> None:
    """Run swift build -c release in the given directory. Exits on failure."""
    r = subprocess.run(
        ["swift", "build", "-c", "release"],
        cwd=cwd,
        timeout=300,
        **({"capture_output": True, "text": True} if not verbose else {}),
    )
    if r.returncode != 0:
        error(f"{label} build failed")
        if not verbose and r.stderr:
            click.echo(r.stderr)
        sys.exit(1)
    info(f"{label} built successfully")


def _run_in(cwd: Path, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
    """Run a shell command in a specific directory."""
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout, cwd=cwd)


def prepare_baseline_workspace(rev: str) -> tuple[Path, str]:
    """Ensure a jj workspace exists at the given revision. Returns (workspace_dir, display_label).

    Reuses an existing workspace (preserving .build cache) when possible,
    falling back to fresh creation.  Must be called before any parallel builds
    since it uses jj.
    """
    change_id, description = resolve_jj_revision(rev)
    short_id = change_id[:8]
    label = f"{short_id}: {description}" if description != "(no description)" else short_id

    info(f"Preparing baseline workspace for revision '{rev}' ({label})...")

    # Warn if baseline is the same as current working copy
    current = run("jj log -r @ --no-graph -T change_id")
    if current.returncode == 0 and current.stdout.strip() == change_id:
        warn(f"Revision '{rev}' resolves to the current working copy — self-comparison will be meaningless")

    # Try to reuse existing workspace (preserves .build cache for faster incremental builds)
    if BASELINE_WORKSPACE_DIR.exists():
        # Sync workspace in case repo was updated since it was last used
        _run_in(BASELINE_WORKSPACE_DIR, "jj workspace update-stale")
        # Rebase the (empty) working copy onto the target revision
        r = _run_in(BASELINE_WORKSPACE_DIR, f"jj rebase -d '{rev}'")
        if r.returncode == 0:
            info("Reused existing baseline workspace (incremental build)")
            return BASELINE_WORKSPACE_DIR, label
        warn(f"Failed to update existing workspace: {r.stderr.strip()}")
        info("Recreating baseline workspace from scratch...")

    # Fresh creation
    if BASELINE_WORKSPACE_DIR.exists():
        shutil.rmtree(BASELINE_WORKSPACE_DIR)
    run(f"jj workspace forget {BASELINE_WORKSPACE_NAME}")  # ignore errors

    r = run(f"jj workspace add {BASELINE_WORKSPACE_DIR} --name {BASELINE_WORKSPACE_NAME} -r '{rev}'")
    if r.returncode != 0:
        error(f"Failed to create jj workspace: {r.stderr.strip()}")
        sys.exit(1)

    return BASELINE_WORKSPACE_DIR, label


def build_baseline(rev: str, *, verbose: bool = False) -> tuple[Path, str]:
    """Create a jj workspace at the given revision, build it, return (binary_path, display_label)."""
    workspace_dir, label = prepare_baseline_workspace(rev)

    info("Building baseline binary (swift build -c release)...")
    _swift_build("Baseline", cwd=workspace_dir, verbose=verbose)

    binary = workspace_dir / ".build" / "release" / "iosef"
    if not binary.exists():
        error(f"Baseline binary not found at {binary}")
        cleanup_baseline()
        sys.exit(1)

    return binary, label


def cleanup_baseline() -> None:
    """Forget the baseline jj workspace and remove its directory."""
    info("Cleaning up baseline workspace...")
    run(f"jj workspace forget {BASELINE_WORKSPACE_NAME}")
    if BASELINE_WORKSPACE_DIR.exists():
        shutil.rmtree(BASELINE_WORKSPACE_DIR)


# --- prerequisites ---


def get_booted_udid() -> str | None:
    r = run("xcrun simctl list devices -j")
    if r.returncode != 0:
        return None
    data = json.loads(r.stdout)
    for runtime, devices in data.get("devices", {}).items():
        for d in devices:
            if d.get("state") == "Booted":
                return d["udid"]
    return None


def check_prerequisites(mode: str) -> None:
    required: list[str] = ["hyperfine"]
    if mode in ("mcp", "all"):
        required += ["mcp", "node"]
    missing = [cmd for cmd in required if not shutil.which(cmd)]
    if missing:
        error(f"Missing required tools: {', '.join(missing)}")
        install = {
            "hyperfine": "brew install hyperfine",
            "mcp": "brew tap f/mcptools && brew install mcp",
            "node": "brew install node",
        }
        click.echo("\nInstall with:")
        for cmd in missing:
            click.echo(f"  {install.get(cmd, f'install {cmd}')}")
        sys.exit(1)


# --- smoke tests ---


def smoke_test(label: str, server_cmd: str) -> None:
    info(f"Smoke testing {label} server...")
    try:
        r = run(f"mcp call get_booted_sim_id {server_cmd}", timeout=5)
        if r.returncode != 0:
            error(f"{label} smoke test failed: {r.stderr.strip()}")
            sys.exit(1)
    except subprocess.TimeoutExpired:
        error(f"{label} smoke test timed out after 5s")
        sys.exit(1)


def idb_connect(idb: str, udid: str) -> None:
    """Ensure idb companion is connected so benchmark doesn't measure startup."""
    info("Connecting idb companion (ensures daemon is running)...")
    r = run(f"{idb} connect {udid}", timeout=15)
    if r.returncode != 0:
        warn(f"idb connect returned non-zero: {r.stderr.strip()}")
    else:
        info("idb companion connected")


def cli_smoke_test(swift_bin: str, idb: str, udid: str) -> None:
    """Quick smoke test for both Swift CLI and idb."""
    info("Smoke testing Swift CLI...")
    try:
        r = run(f"{swift_bin} tap --x 0 --y 0 --udid {udid}", timeout=10)
        if r.returncode != 0:
            error(f"Swift CLI smoke test failed: {r.stderr.strip()}")
            sys.exit(1)
    except subprocess.TimeoutExpired:
        error("Swift CLI smoke test timed out")
        sys.exit(1)

    info("Smoke testing idb...")
    try:
        r = run(f"{idb} ui tap --udid {udid} --json -- 0 0", timeout=10)
        if r.returncode != 0:
            error(f"idb smoke test failed: {r.stderr.strip()}")
            sys.exit(1)
    except subprocess.TimeoutExpired:
        error("idb smoke test timed out")
        sys.exit(1)

    info("CLI smoke tests passed")


# --- MCP command builder ---


def mcp_call_cmd(tool: str, params: dict | None, udid: str, server_cmd: str) -> str:
    """Build the mcp call command string, injecting udid into params."""
    if params is not None:
        p = {**params, "udid": udid}
    elif tool != "get_booted_sim_id":
        p = {"udid": udid}
    else:
        p = None

    # perl alarm gives us a 5s timeout on macOS (no coreutils `timeout`)
    cmd = f"perl -e 'alarm 5; exec @ARGV' -- mcp call {tool}"
    if p:
        cmd += f" -p '{json.dumps(p)}'"
    cmd += f" {server_cmd}"
    return cmd


# --- benchmarking ---


def bench(
    tool: str,
    params: dict | None,
    udid: str,
    swift_cmd: str,
    node_cmd: str,
    warmup: int,
    min_runs: int,
    *,
    baseline_swift_cmd: str | None = None,
    baseline_label: str | None = None,
) -> None:
    info(f"Benchmarking: {tool}")

    swift_full = mcp_call_cmd(tool, params, udid, swift_cmd)
    node_full = mcp_call_cmd(tool, params, udid, node_cmd)

    # Pre-check if node MCP command works; if not, skip it
    node_ok = subprocess.run(node_full, shell=True, capture_output=True, timeout=10).returncode == 0

    current_name = "swift (current)" if baseline_swift_cmd else "swift"

    hyperfine_cmd = [
        "hyperfine",
        "--warmup", str(warmup),
        "--min-runs", str(min_runs),
        "--reference", swift_full,
        "--reference-name", f"{current_name}: {tool}",
    ]

    if baseline_swift_cmd:
        baseline_full = mcp_call_cmd(tool, params, udid, baseline_swift_cmd)
        hyperfine_cmd += [
            "--command-name", f"swift ({baseline_label}): {tool}", baseline_full,
        ]

    if node_ok:
        hyperfine_cmd += ["--command-name", f"node: {tool}", node_full]
    else:
        warn(f"node MCP command failed for '{tool}', benchmarking without node baseline")

    hyperfine_cmd += [
        "--export-json", str(RESULTS_DIR / f"{tool}.json"),
        "--export-markdown", str(RESULTS_DIR / f"{tool}.md"),
    ]

    subprocess.run(hyperfine_cmd, check=True)
    click.echo()


def cli_bench(
    name: str,
    swift_cmd: str,
    baseline_cmd: str,
    baseline_label: str,
    warmup: int,
    min_runs: int,
    *,
    self_baseline_cmd: str | None = None,
    self_baseline_label: str | None = None,
) -> None:
    info(f"Benchmarking (CLI): {name}")

    # Wrap commands in perl alarm timeout
    swift_full = f"perl -e 'alarm 5; exec @ARGV' -- {swift_cmd}"
    baseline_full = f"perl -e 'alarm 5; exec @ARGV' -- {baseline_cmd}"

    # Pre-check if external baseline command works; if not, skip it
    baseline_ok = subprocess.run(baseline_cmd, shell=True, capture_output=True, timeout=10).returncode == 0

    current_name = "swift-cli (current)" if self_baseline_cmd else "swift-cli"

    hyperfine_cmd = [
        "hyperfine",
        "--warmup", str(warmup),
        "--min-runs", str(min_runs),
        "--reference", swift_full,
        "--reference-name", f"{current_name}: {name}",
    ]

    if self_baseline_cmd:
        self_baseline_full = f"perl -e 'alarm 5; exec @ARGV' -- {self_baseline_cmd}"
        hyperfine_cmd += [
            "--command-name", f"swift-cli ({self_baseline_label}): {name}", self_baseline_full,
        ]

    if baseline_ok:
        hyperfine_cmd += ["--command-name", f"{baseline_label}: {name}", baseline_full]
    else:
        warn(f"{baseline_label} command failed for '{name}', benchmarking without external baseline")

    hyperfine_cmd += [
        "--export-json", str(RESULTS_DIR / f"cli_{name}.json"),
        "--export-markdown", str(RESULTS_DIR / f"cli_{name}.md"),
    ]

    subprocess.run(hyperfine_cmd, check=True)
    click.echo()


# --- summary ---


def _speedup_table(json_files: list[Path], labels: list[str]) -> list[str]:
    """Build a markdown speedup summary table from hyperfine JSON files.

    labels[0] is the primary (current) command; subsequent labels are each
    compared against it as speedup = other_mean / current_mean.
    """
    n_labels = len(labels)
    lines = []

    # Header: Tool | primary (mean) | [comparison (mean) | Speedup] ...
    header_parts = ["Tool", f"{labels[0]} (mean)"]
    for label in labels[1:]:
        header_parts += [f"{label} (mean)", "Speedup"]
    lines.append("| " + " | ".join(header_parts) + " |")
    lines.append("|" + "|".join("------" for _ in header_parts) + "|")

    for jf in json_files:
        tool = jf.stem.removeprefix("cli_")
        data = json.loads(jf.read_text())
        results = data["results"]

        row = [tool, f"{results[0]['mean']:.3f}s"]
        for i in range(1, n_labels):
            if i < len(results):
                b_mean = results[i]["mean"]
                speedup = b_mean / results[0]["mean"]
                row += [f"{b_mean:.3f}s", f"{speedup:.2f}x"]
            else:
                row += ["N/A", "N/A"]
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    return lines


def generate_summary(
    mode: str,
    swift_cmd: str,
    node_cmd: str | None,
    idb_cmd: str | None,
    warmup: int,
    min_runs: int,
    baseline_label: str | None = None,
) -> str:
    lines = [
        "# iOS Simulator MCP Benchmark",
        "",
        f"Date: {subprocess.run('date', capture_output=True, text=True).stdout.strip()}",
        "",
        f"- Mode: `{mode}`",
        f"- Swift: `{swift_cmd}`",
    ]
    if node_cmd:
        lines.append(f"- Node: `{node_cmd}`")
    if idb_cmd:
        lines.append(f"- idb: `{idb_cmd}`")
    if baseline_label:
        lines.append(f"- Self-comparison baseline: `{baseline_label}`")
    lines += [f"- Warmup runs: {warmup} | Min runs: {min_runs}", ""]

    # MCP results (files without cli_ prefix)
    mcp_mds = sorted(f for f in RESULTS_DIR.glob("*.md") if not f.name.startswith("cli_") and f.name != "summary.md")
    mcp_jsons = sorted(f for f in RESULTS_DIR.glob("*.json") if not f.name.startswith("cli_"))
    if mcp_mds:
        if baseline_label:
            title = f"MCP Benchmark (Swift current vs {baseline_label} vs Node)"
        else:
            title = "MCP Benchmark (Swift MCP vs Node MCP)"
        lines.append(f"# {title}")
        lines.append("")
        for md_file in mcp_mds:
            lines.append(f"## {md_file.stem}")
            lines.append("")
            lines.append(md_file.read_text())
            lines.append("")
        if mcp_jsons:
            lines.append("## MCP Speedup Summary")
            lines.append("")
            if baseline_label:
                mcp_labels = ["Swift (current)", f"Swift ({baseline_label})", "Node"]
            else:
                mcp_labels = ["Swift", "Node"]
            lines += _speedup_table(mcp_jsons, mcp_labels)

    # CLI results (files with cli_ prefix)
    cli_mds = sorted(f for f in RESULTS_DIR.glob("cli_*.md"))
    cli_jsons = sorted(f for f in RESULTS_DIR.glob("cli_*.json"))
    if cli_mds:
        if baseline_label:
            title = f"CLI Benchmark (Swift current vs {baseline_label} vs idb)"
        else:
            title = "CLI Benchmark (Swift CLI vs idb)"
        lines.append(f"# {title}")
        lines.append("")
        for md_file in cli_mds:
            display = md_file.stem.removeprefix("cli_")
            lines.append(f"## {display}")
            lines.append("")
            lines.append(md_file.read_text())
            lines.append("")
        if cli_jsons:
            lines.append("## CLI Speedup Summary")
            lines.append("")
            if baseline_label:
                cli_labels = ["Swift CLI (current)", f"Swift CLI ({baseline_label})", "idb"]
            else:
                cli_labels = ["Swift CLI", "idb"]
            lines += _speedup_table(cli_jsons, cli_labels)

    return "\n".join(lines)


@click.command()
@click.option("--swift-bin", default=SWIFT_BIN_DEFAULT, show_default=True, help="Path to Swift MCP binary")
@click.option("--node-server", default=NODE_SERVER_DEFAULT, show_default=True, help="Node MCP server command")
@click.option("--idb", "idb_path", default=IDB_DEFAULT, show_default=True, help="Path to idb binary")
@click.option("--warmup", default=2, show_default=True, help="Hyperfine warmup runs")
@click.option("--min-runs", default=5, show_default=True, help="Hyperfine minimum runs")
@click.option("--tool", "tools", multiple=True, help="Only benchmark specific tool(s). Can be repeated.")
@click.option("--udid", default=None, help="Simulator UDID (auto-detected if omitted)")
@click.option(
    "--mode",
    type=click.Choice(["mcp", "cli", "all"]),
    default="cli",
    show_default=True,
    help="Benchmark mode: mcp (Swift vs Node MCP), cli (Swift CLI vs idb), or all.",
)
@click.option(
    "--from-version",
    "from_version",
    default="main",
    show_default=True,
    help="jj revision to use as self-comparison baseline.",
)
@click.option(
    "--no-from-version",
    "no_from_version",
    is_flag=True,
    default=False,
    help="Disable self-comparison (only compare against external baselines).",
)
@click.option("-v", "--verbose", is_flag=True, default=False, help="Show swift build output.")
def main(
    swift_bin: str,
    node_server: str,
    idb_path: str,
    warmup: int,
    min_runs: int,
    tools: tuple[str, ...],
    udid: str | None,
    mode: str,
    from_version: str,
    no_from_version: bool,
    verbose: bool,
) -> None:
    """Benchmark Swift MCP vs Node MCP and/or Swift CLI vs idb."""
    # cd to project root
    os.chdir(Path(__file__).resolve().parent.parent)

    check_prerequisites(mode)

    # Resolve UDID
    if udid is None:
        udid = get_booted_udid()
        if udid is None:
            error("No booted iOS Simulator found. Boot one first:")
            click.echo("  xcrun simctl boot <device-udid>")
            sys.exit(1)
    info(f"Using simulator UDID: {udid}")

    # Build binaries (current + baseline in parallel when possible)
    do_baseline = not no_from_version
    baseline_bin: Path | None = None
    baseline_label: str | None = None

    try:
        if do_baseline:
            # Prepare baseline workspace first (needs jj, must be sequential)
            baseline_workspace, baseline_label = prepare_baseline_workspace(from_version)

            # Build both binaries in parallel
            info("Building current + baseline binaries in parallel...")
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                current_fut = pool.submit(_swift_build, "Current", verbose=verbose)
                baseline_fut = pool.submit(_swift_build, "Baseline", cwd=baseline_workspace, verbose=verbose)
                current_fut.result()
                baseline_fut.result()

            baseline_bin = baseline_workspace / ".build" / "release" / "iosef"
            if not baseline_bin.exists():
                error(f"Baseline binary not found at {baseline_bin}")
                cleanup_baseline()
                sys.exit(1)
        else:
            # No baseline — just build current
            info("Building current release binary...")
            _swift_build("Current", verbose=verbose)

        # MCP-mode prerequisites
        swift_mcp_cmd = f"{swift_bin} mcp"
        if mode in ("mcp", "all"):
            node_index = node_server.split()[-1]
            if not Path(node_index).exists():
                error(f"Node server not found at {node_index}")
                click.echo(f"  cd {Path(node_index).parent.parent} && npm run build")
                sys.exit(1)
            smoke_test("Swift", swift_mcp_cmd)
            smoke_test("Node", node_server)
            info("Both MCP servers responding")

        # CLI-mode prerequisites
        if mode in ("cli", "all"):
            if not Path(idb_path).exists():
                error(f"idb not found at {idb_path}")
                click.echo("  Install with: brew install idb-companion")
                sys.exit(1)
            idb_connect(idb_path, udid)
            cli_smoke_test(swift_bin, idb_path, udid)

        # Setup results dir
        if RESULTS_DIR.exists():
            shutil.rmtree(RESULTS_DIR)
        RESULTS_DIR.mkdir(parents=True)

        # --- MCP benchmarks ---
        if mode in ("mcp", "all"):
            bench_tools = TOOLS
            if tools:
                tool_set = set(tools)
                bench_tools = [(t, p) for t, p in TOOLS if t in tool_set]
                if not bench_tools:
                    error(f"No matching MCP tools. Available: {', '.join(t for t, _ in TOOLS)}")
                    sys.exit(1)
            for tool, params in bench_tools:
                bench(
                    tool, params, udid, swift_mcp_cmd, node_server, warmup, min_runs,
                    baseline_swift_cmd=f"{baseline_bin} mcp" if baseline_bin else None,
                    baseline_label=baseline_label,
                )

        # --- CLI benchmarks ---
        if mode in ("cli", "all"):
            cli_tools = CLI_TOOLS
            if tools:
                tool_set = set(tools)
                cli_tools = [(n, s, b, l) for n, s, b, l in CLI_TOOLS if n in tool_set]
                if not cli_tools:
                    error(f"No matching CLI tools. Available: {', '.join(n for n, _, _, _ in CLI_TOOLS)}")
                    sys.exit(1)
            for name, swift_tpl, baseline_tpl, ext_baseline_label in cli_tools:
                swift_full = swift_tpl.format(swift_bin=swift_bin, udid=udid)
                baseline_full = baseline_tpl.format(idb=idb_path, udid=udid)
                self_cmd = None
                if baseline_bin:
                    self_cmd = swift_tpl.format(swift_bin=str(baseline_bin), udid=udid)
                cli_bench(
                    name, swift_full, baseline_full, ext_baseline_label, warmup, min_runs,
                    self_baseline_cmd=self_cmd,
                    self_baseline_label=baseline_label,
                )

        # Summary
        summary = generate_summary(
            mode=mode,
            swift_cmd=swift_bin,
            node_cmd=node_server if mode in ("mcp", "all") else None,
            idb_cmd=idb_path if mode in ("cli", "all") else None,
            warmup=warmup,
            min_runs=min_runs,
            baseline_label=baseline_label,
        )
        summary_path = RESULTS_DIR / "summary.md"
        summary_path.write_text(summary)

        info(f"Results saved to {RESULTS_DIR}/")
        info(f"Summary written to {summary_path}")
        click.echo()
    finally:
        pass  # Baseline workspace preserved for incremental builds on next run


if __name__ == "__main__":
    main()
