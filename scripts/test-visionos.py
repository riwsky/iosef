#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["click"]
# ///
"""Run the visionOS gauntlet: drive VisionTestApp through iosef and check every interaction
landed, by watching the app's log.

Covers taps across a window, text entry, dragging in a window, opening and moving a volume,
tapping and dragging an entity in the volume, tapping and dragging entities in an immersive
space, and moving the viewer's head (turning to content off to the side, recentering).

Each run starts from a known layout: the head back in the default seat (`iosef look`), anything
else recentered (`iosef recenter`), and the app reinstalled so visionOS forgets where its
windows were moved and opens them in their default place.

Targets are found by accessibility selector (identifiers in the window, labels on the
RealityKit entities), so the checks also cover iosef projecting each element's 3D placement
onto the screen: after the head turns, after a recenter, and after the volume moves.

visionOS accessibility doesn't expose app elements yet, so targets are screen points for
the Apple Vision Pro (4K) simulator (1920x1080 points) with VisionTestApp's window in its
default placement. If the layout changes, re-measure them from `iosef view`.
"""

import json
import re
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import click

ROOT = Path(__file__).resolve().parent.parent
APP_PATH = ROOT / "VisionTestApp/DerivedData/Build/Products/Debug-xrsimulator/VisionTestApp.app"
BUNDLE_ID = "com.mcp-test.playground.visionapp"  # also the app's log subsystem

# Entities are labelled, not identified; the role keeps "Orb" from matching "Orb tap count".
VOLUME_CUBE = ("--role", "AXButton", "--name", "Volume cube")
ORB = ("--role", "AXButton", "--name", "Orb")
IMMERSIVE_CUBE = ("--role", "AXButton", "--name", "Immersive cube")
GRAB_BAR = ("--name", "App Placement Bar")
ORB_YAW = -26.565                # turning left by atan(1/2) puts the orb dead ahead
SCREEN_CENTRE = (960, 540)
# Scenes log "ready" when SwiftUI/RealityKit build them, a moment before they've animated into
# place and become hit-testable.
SETTLE = 2.0


class AppLog:
    """Streams the app's log lines in the background so each step can wait for its own."""

    def __init__(self, udid: str):
        self.lines: list[str] = []
        self.proc = subprocess.Popen(
            ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "compact",
             "--predicate", f'subsystem == "{BUNDLE_ID}"'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._pump, daemon=True).start()
        time.sleep(2)  # log stream takes a moment to attach

    def _pump(self):
        for line in self.proc.stdout:
            if "[VisionTest]" in line:
                self.lines.append(line.split("[VisionTest]", 1)[1].strip())

    def mark(self) -> int:
        return len(self.lines)

    def wait_for(self, since: int, pattern: str, timeout: float = 4.0) -> re.Match | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for line in self.lines[since:]:
                if m := re.search(pattern, line):
                    return m
            time.sleep(0.1)
        return None

    def close(self):
        self.proc.terminate()


@dataclass
class Result:
    name: str
    ok: bool
    detail: str = ""


class Gauntlet:
    def __init__(self, iosef: str, udid: str):
        self.iosef, self.udid = iosef, udid
        self.results: list[Result] = []
        self.log = AppLog(udid)

    def run(self, *args: str) -> str:
        return subprocess.run([self.iosef, *args, "--device", self.udid],
                              check=True, capture_output=True, text=True).stdout

    def tap(self, point):
        self.run("tap", "--x", str(point[0]), "--y", str(point[1]))

    def tap_element(self, *selector: str):
        self.run("tap", *selector)

    def centers(self, *selector: str) -> list[tuple[float, float]]:
        """Screen centers of every element matching `selector`, from `find`'s (x±w, y±h)."""
        out = self.run("find", *selector)
        return [(float(x), float(y)) for x, y in re.findall(r"\((-?[\d.]+)±[\d.]+, (-?[\d.]+)±[\d.]+\)", out)]

    def center(self, *selector: str) -> tuple[float, float]:
        found = self.centers(*selector)
        if not found:
            raise click.ClickException(f"no element with a frame matches {' '.join(selector)}")
        return found[0]

    def drag(self, start, end, duration=0.6):
        self.run("swipe", "--x-start", str(start[0]), "--y-start", str(start[1]),
                 "--x-end", str(end[0]), "--y-end", str(end[1]), "--duration", str(duration))

    def record(self, name: str, ok: bool, detail: str):
        self.results.append(Result(name, ok, detail))
        click.echo(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")

    def check(self, name: str, action, pattern: str, verify=None, timeout=4.0, expect=True):
        """Run `action` and check the app logs `pattern` (or, with expect=False, doesn't)."""
        mark = self.log.mark()
        action()
        m = self.log.wait_for(mark, pattern, timeout if expect else 2.0)
        if expect:
            ok = m is not None and (verify is None or verify(m))
            detail = m.group(0) if m else f"no log matching /{pattern}/"
        else:
            ok, detail = m is None, m.group(0) if m else "nothing, as expected"
        self.record(name, ok, detail)

    def screenshot(self, path: Path):
        self.run("view", "--output", str(path))


def default_sim_name() -> str:
    """The visionOS simulator build-test-app.sh creates: <VCS root's name>-vision."""
    for cmd in (["jj", "root"], ["git", "rev-parse", "--show-toplevel"]):
        root = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if root.returncode == 0:
            return f"{Path(root.stdout.strip()).name}-vision"
    return f"{ROOT.name}-vision"


def find_udid(name: str) -> str:
    out = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"],
                         check=True, capture_output=True, text=True).stdout
    for runtime, devices in json.loads(out)["devices"].items():
        if "xrOS" in runtime:
            for d in devices:
                if d["name"] == name and d["isAvailable"]:
                    return d["udid"]
    raise click.ClickException(f"no visionOS simulator named {name!r}; run scripts/build-test-app.sh visionos")


@click.command()
@click.option("--device", help="visionOS simulator UDID (default: the build script's <repo>-vision sim)")
@click.option("--iosef", "iosef_bin", default=str(ROOT / ".build/debug/iosef"), show_default=True)
@click.option("--build/--no-build", default=True, help="Build iosef and VisionTestApp first")
@click.option("--screenshots", type=click.Path(path_type=Path),
              help="Directory for a screenshot after each scene (default: a temp dir)")
def main(device, iosef_bin, build, screenshots):
    if build:
        subprocess.run(["swift", "build"], cwd=ROOT, check=True)
        subprocess.run([str(ROOT / "scripts/build-test-app.sh"), "visionos"], cwd=ROOT, check=True)
    udid = device or find_udid(default_sim_name())
    shots = screenshots or Path(tempfile.mkdtemp(prefix="iosef-visionos-"))
    shots.mkdir(parents=True, exist_ok=True)

    g = Gauntlet(iosef_bin, udid)
    try:
        # A known layout: default head, a fresh install (visionOS remembers where an app's
        # windows were moved), then recenter so nothing else is in the way.
        def simctl(*args):
            subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True)

        def fresh_launch():
            g.run("look")
            g.run("recenter")
            simctl("uninstall", udid, BUNDLE_ID)
            simctl("install", udid, str(APP_PATH))
            simctl("launch", udid, BUNDLE_ID)

        def launched():
            g.check("fresh launch", fresh_launch, r"Window ready", timeout=15)
            # SurfBoard takes a few seconds more to expose the new scene to accessibility.
            g.run("wait", "--identifier", "grid_0_0", "--timeout", "30")
            time.sleep(SETTLE)

        launched()

        # Window: every grid button, so corners and edges are covered, not just the centre.
        for r in range(3):
            for c in range(5):
                g.check(f"tap R{r}C{c}", lambda r=r, c=c: g.tap_element("--identifier", f"grid_{r}_{c}"),
                        rf"Button tapped: R{r}C{c}\b")

        # Head: turn away and recenter; the window follows and taps aim from the turned head,
        # where the element frames are projected from too. This runs before text entry, since
        # an open keyboard is recentered along with the window and shifts it. Then a fresh
        # launch puts the window back in its default place.
        g.check("turn 60 degrees right, recenter, tap R1C3",
                lambda: (g.run("look", "--yaw", "60"), g.run("recenter"), time.sleep(SETTLE),
                         g.tap_element("--identifier", "grid_1_3")),
                r"Button tapped: R1C3\b")
        g.screenshot(shots / "1b-turned-recentered.png")
        g.check("look straight ahead, recenter, tap R1C1",
                lambda: (g.run("look"), g.run("recenter"), time.sleep(SETTLE),
                         g.tap_element("--identifier", "grid_1_1")),
                r"Button tapped: R1C1\b")
        launched()

        g.check("type into text field",
                lambda: (g.tap_element("--identifier", "text_field"), time.sleep(1.5),
                         g.run("type", "--text", "hello vision")),
                r"Text changed: hello vision$")

        def drag_token():
            token = g.center("--identifier", "drag_token")
            g.drag(token, (token[0] + 120, token[1]))
        g.check("drag token 120pt right", drag_token, r"Drag ended: (-?\d+), (-?\d+)",
                verify=lambda m: abs(int(m.group(1)) - 120) <= 20 and abs(int(m.group(2))) <= 20)
        g.screenshot(shots / "1-window.png")

        # Volume: open it, poke and drag its cube, then move the whole volume by its bar.
        g.check("open volume", lambda: g.tap_element("--identifier", "volume_toggle"), r"Volume ready", timeout=6)
        g.run("wait", *VOLUME_CUBE, "--timeout", "15")
        time.sleep(SETTLE)
        g.check("tap volume cube", lambda: g.tap_element(*VOLUME_CUBE), r"Volume cube tapped")

        def drag_cube():
            cube = g.center(*VOLUME_CUBE)
            g.drag(cube, (cube[0] + 100, cube[1]))
        g.check("drag volume cube", drag_cube, r"Volume cube moved to (-?\d+), (-?\d+), (-?\d+) cm",
                verify=lambda m: int(m.group(1)) >= 5)
        g.screenshot(shots / "2-volume.png")

        # The volume's bar is the placement bar nearest the cube (the window has one too). A
        # 300pt drag moves the volume most of the way to the screen's right edge.
        cube = g.center(*VOLUME_CUBE)
        bar = min(g.centers(*GRAB_BAR), key=lambda b: (b[0] - cube[0]) ** 2 + (b[1] - cube[1]) ** 2)
        g.check("move volume window (cube no longer where it was)",
                lambda: (g.drag(bar, (bar[0] + 300, bar[1]), 1.0), time.sleep(1.5), g.tap(cube)),
                r"Volume cube tapped", expect=False)
        moved = (g.centers(*VOLUME_CUBE) or [None])[0]
        g.record("cube's frame follows the volume", moved is not None and moved[0] - cube[0] > 120,
                 f"{cube} -> {moved or 'off screen'}")
        g.check("tap volume cube where it went", lambda: g.tap_element(*VOLUME_CUBE), r"Volume cube tapped")

        # Immersive space: enter it, tap the orb (head-on and by turning to it), drag the cube.
        g.check("enter immersive space", lambda: g.tap_element("--identifier", "immersion_toggle"),
                r"Immersive space ready", timeout=6)
        g.run("wait", *ORB, "--timeout", "15")
        time.sleep(SETTLE)
        g.check("tap orb", lambda: g.tap_element(*ORB), r"Orb tapped")
        g.check("turn to face the orb and tap the centre of view",
                lambda: (g.run("look", "--yaw", str(ORB_YAW)), g.tap(SCREEN_CENTRE)),
                r"Orb tapped")
        g.screenshot(shots / "3-facing-orb.png")
        orb = (g.centers(*ORB) or [None])[0]
        g.record("orb's frame follows the head", orb is not None and abs(orb[0] - SCREEN_CENTRE[0]) < 30,
                 f"{orb or 'off screen'}")
        g.run("look")

        def drag_immersive_cube():
            cube = g.center(*IMMERSIVE_CUBE)
            g.drag(cube, (cube[0] - 200, cube[1] - 80), 0.8)
        g.check("drag immersive cube", drag_immersive_cube,
                r"Immersive cube moved to (-?\d+), (-?\d+), (-?\d+) cm",
                verify=lambda m: int(m.group(1)) < 95 and int(m.group(2)) > 160)
        g.screenshot(shots / "4-immersive.png")
        g.check("leave immersive space", lambda: g.tap_element("--identifier", "immersion_toggle"),
                r"Immersed: false", timeout=6)
    finally:
        g.log.close()

    failed = [r for r in g.results if not r.ok]
    click.echo(f"\n{len(g.results) - len(failed)}/{len(g.results)} passed. Screenshots: {shots}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
