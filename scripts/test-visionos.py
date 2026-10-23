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

GRID_X = [627, 793, 960, 1126, 1293]
GRID_Y = [463, 504, 545]
TEXT_FIELD = (822, 592)
DRAG_TOKEN = (1097, 618)
OPEN_VOLUME = (902, 710)
ENTER_SPACE = (1020, 710)
VOLUME_CUBE = (1046, 686)        # where the volume opens, in front of the window
VOLUME_GRAB_BAR = (1060, 853)
IMMERSIVE_CUBE = (1440, 540)     # world (1, 1.6, -2) under a 90-degree camera
ORB = (480, 540)                 # world (-1, 1.6, -2)
ORB_YAW = -26.565                # turning left by atan(1/2) puts the orb dead ahead
SCREEN_CENTRE = (960, 540)
# After a recenter the window is back in front, but its height varies by OS version (visionOS
# 26.4 lifts it to eye level, ~47pt up; 27 doesn't). y=500 is on a button either way (row 1 at
# its default height, row 2 when lifted), so recenter checks tap there and accept any row.
RECENTERED_Y = 500
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

    def run(self, *args: str):
        subprocess.run([self.iosef, *args, "--device", self.udid],
                       check=True, capture_output=True, text=True)

    def tap(self, point):
        self.run("tap", "--x", str(point[0]), "--y", str(point[1]))

    def drag(self, start, end, duration=0.6):
        self.run("swipe", "--x-start", str(start[0]), "--y-start", str(start[1]),
                 "--x-end", str(end[0]), "--y-end", str(end[1]), "--duration", str(duration))

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
        self.results.append(Result(name, ok, detail))
        click.echo(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")

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

        g.check("fresh launch", fresh_launch, r"Window ready", timeout=15)
        time.sleep(SETTLE)

        # Window: every grid button, so corners and edges are covered, not just the centre.
        for r, y in enumerate(GRID_Y):
            for c, x in enumerate(GRID_X):
                g.check(f"tap R{r}C{c}", lambda x=x, y=y: g.tap((x, y)), rf"Button tapped: R{r}C{c}\b")

        # Head: turn away and recenter; the window follows (at eye level) and taps aim from
        # the turned head. This runs before text entry, since an open keyboard is recentered
        # along with the window and shifts it. Then a fresh launch puts the window back where
        # the rest expects it.
        g.check("turn 60 degrees right, recenter, tap",
                lambda: (g.run("look", "--yaw", "60"), g.run("recenter"), g.tap((GRID_X[3], RECENTERED_Y))),
                r"Button tapped: R\dC3\b")
        g.screenshot(shots / "1b-turned-recentered.png")
        g.check("look straight ahead, recenter, tap",
                lambda: (g.run("look"), g.run("recenter"), g.tap((GRID_X[1], RECENTERED_Y))),
                r"Button tapped: R\dC1\b")
        g.check("fresh launch again", fresh_launch, r"Window ready", timeout=15)
        time.sleep(SETTLE)

        g.check("type into text field",
                lambda: (g.tap(TEXT_FIELD), time.sleep(1.5), g.run("type", "--text", "hello vision")),
                r"Text changed: hello vision$")

        g.check("drag token 120pt right",
                lambda: g.drag(DRAG_TOKEN, (DRAG_TOKEN[0] + 120, DRAG_TOKEN[1])),
                r"Drag ended: (-?\d+), (-?\d+)",
                verify=lambda m: abs(int(m.group(1)) - 120) <= 20 and abs(int(m.group(2))) <= 20)
        g.screenshot(shots / "1-window.png")

        # Volume: open it, poke and drag its cube, then move the whole volume by its bar.
        g.check("open volume", lambda: g.tap(OPEN_VOLUME), r"Volume ready", timeout=6)
        time.sleep(SETTLE)
        g.check("tap volume cube", lambda: g.tap(VOLUME_CUBE), r"Volume cube tapped")
        g.check("drag volume cube", lambda: g.drag(VOLUME_CUBE, (VOLUME_CUBE[0] + 100, VOLUME_CUBE[1])),
                r"Volume cube moved to (-?\d+), (-?\d+), (-?\d+) cm",
                verify=lambda m: int(m.group(1)) >= 5)
        g.screenshot(shots / "2-volume.png")
        moved_cube = (VOLUME_CUBE[0] + 85, VOLUME_CUBE[1])
        g.check("move volume window (cube no longer where it was)",
                lambda: (g.drag(VOLUME_GRAB_BAR, (VOLUME_GRAB_BAR[0] + 500, VOLUME_GRAB_BAR[1]), 1.0),
                         time.sleep(1.5), g.tap(moved_cube)),
                r"Volume cube tapped", expect=False)

        # Immersive space: enter it, tap the orb (head-on and by turning to it), drag the cube.
        g.check("enter immersive space", lambda: g.tap(ENTER_SPACE), r"Immersive space ready", timeout=6)
        time.sleep(SETTLE)
        g.check("tap orb", lambda: g.tap(ORB), r"Orb tapped")
        g.check("turn to face the orb and tap the centre of view",
                lambda: (g.run("look", "--yaw", str(ORB_YAW)), g.tap(SCREEN_CENTRE)),
                r"Orb tapped")
        g.screenshot(shots / "3-facing-orb.png")
        g.run("look")
        g.check("drag immersive cube",
                lambda: g.drag(IMMERSIVE_CUBE, (IMMERSIVE_CUBE[0] - 200, IMMERSIVE_CUBE[1] - 80), 0.8),
                r"Immersive cube moved to (-?\d+), (-?\d+), (-?\d+) cm",
                verify=lambda m: int(m.group(1)) < 95 and int(m.group(2)) > 160)
        g.screenshot(shots / "4-immersive.png")
        g.check("leave immersive space", lambda: g.tap(ENTER_SPACE), r"Immersed: false", timeout=6)
    finally:
        g.log.close()

    failed = [r for r in g.results if not r.ok]
    click.echo(f"\n{len(g.results) - len(failed)}/{len(g.results)} passed. Screenshots: {shots}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
