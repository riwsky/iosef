#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["click"]
# ///
"""Benchmark Swift MCP vs Node MCP (mcp mode) and/or Swift CLI vs idb (cli mode)."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import click

SWIFT_BIN_DEFAULT = ".build/release/ios-simulator-mcp"
NODE_SERVER_DEFAULT = "node /Users/wcybriwsky/build/ios-simulator-mcp/build/index.js"
IDB_DEFAULT = "/Users/wcybriwsky/.local/bin/idb"
RESULTS_DIR = Path("/tmp/ios-sim-mcp-bench")

# MCP-level benchmark tools: (tool_name, extra_params_or_None)
TOOLS: list[tuple[str, dict | None]] = [
    ("get_booted_sim_id", None),
    ("ui_describe_all", None),
    ("ui_describe_point", {"x": 200, "y": 400}),
    ("ui_tap", {"x": 200, "y": 400}),
    ("ui_view", None),
]

# CLI-level benchmark tools: (display_name, swift_cli_template, idb_template)
# Templates use {udid} placeholder.
CLI_TOOLS: list[tuple[str, str, str]] = [
    (
        "ui_describe_all",
        "{swift_bin} cli ui_describe_all udid={udid}",
        "{idb} ui describe-all --udid {udid} --json",
    ),
    (
        "ui_describe_point",
        "{swift_bin} cli ui_describe_point x=200 y=400 udid={udid}",
        "{idb} ui describe-point --udid {udid} --json -- 200 400",
    ),
    (
        "ui_tap",
        "{swift_bin} cli ui_tap x=200 y=400 udid={udid}",
        "{idb} ui tap --udid {udid} --json -- 200 400",
    ),
    (
        "screenshot",
        "{swift_bin} cli ui_view udid={udid}",
        "{idb} screenshot --udid {udid} /tmp/bench_ss.png",
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


def bench(
    tool: str,
    params: dict | None,
    udid: str,
    swift_cmd: str,
    node_cmd: str,
    warmup: int,
    min_runs: int,
) -> None:
    info(f"Benchmarking: {tool}")

    swift_full = mcp_call_cmd(tool, params, udid, swift_cmd)
    node_full = mcp_call_cmd(tool, params, udid, node_cmd)

    hyperfine_cmd = [
        "hyperfine",
        "--warmup", str(warmup),
        "--min-runs", str(min_runs),
        "--command-name", f"swift: {tool}", swift_full,
        "--command-name", f"node: {tool}", node_full,
        "--export-json", str(RESULTS_DIR / f"{tool}.json"),
        "--export-markdown", str(RESULTS_DIR / f"{tool}.md"),
    ]

    subprocess.run(hyperfine_cmd, check=True)
    click.echo()


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
        r = run(f"{swift_bin} cli ui_tap x=0 y=0 udid={udid}", timeout=10)
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


def cli_bench(
    name: str,
    swift_cmd: str,
    idb_cmd: str,
    warmup: int,
    min_runs: int,
) -> None:
    info(f"Benchmarking (CLI): {name}")

    # Wrap both in perl alarm timeout
    swift_full = f"perl -e 'alarm 5; exec @ARGV' -- {swift_cmd}"
    idb_full = f"perl -e 'alarm 5; exec @ARGV' -- {idb_cmd}"

    hyperfine_cmd = [
        "hyperfine",
        "--warmup", str(warmup),
        "--min-runs", str(min_runs),
        "--command-name", f"swift-cli: {name}", swift_full,
        "--command-name", f"idb: {name}", idb_full,
        "--export-json", str(RESULTS_DIR / f"cli_{name}.json"),
        "--export-markdown", str(RESULTS_DIR / f"cli_{name}.md"),
    ]

    subprocess.run(hyperfine_cmd, check=True)
    click.echo()


def _speedup_table(json_files: list[Path], label_a: str, label_b: str) -> list[str]:
    """Build a markdown speedup summary table from hyperfine JSON files."""
    lines = []
    lines.append(f"| Tool | {label_a} (mean) | {label_b} (mean) | Speedup |")
    lines.append("|------|-------------|------------|---------|")
    for jf in json_files:
        tool = jf.stem.removeprefix("cli_")
        data = json.loads(jf.read_text())
        results = data["results"]
        a_mean = results[0]["mean"]
        b_mean = results[1]["mean"]
        speedup = b_mean / a_mean
        lines.append(f"| {tool} | {a_mean:.3f}s | {b_mean:.3f}s | {speedup:.2f}x |")
    lines.append("")
    return lines


def generate_summary(
    mode: str,
    swift_cmd: str,
    node_cmd: str | None,
    idb_cmd: str | None,
    warmup: int,
    min_runs: int,
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
    lines += [f"- Warmup runs: {warmup} | Min runs: {min_runs}", ""]

    # MCP results (files without cli_ prefix)
    mcp_mds = sorted(f for f in RESULTS_DIR.glob("*.md") if not f.name.startswith("cli_") and f.name != "summary.md")
    mcp_jsons = sorted(f for f in RESULTS_DIR.glob("*.json") if not f.name.startswith("cli_"))
    if mcp_mds:
        lines.append("# MCP Benchmark (Swift MCP vs Node MCP)")
        lines.append("")
        for md_file in mcp_mds:
            lines.append(f"## {md_file.stem}")
            lines.append("")
            lines.append(md_file.read_text())
            lines.append("")
        if mcp_jsons:
            lines.append("## MCP Speedup Summary")
            lines.append("")
            lines += _speedup_table(mcp_jsons, "Swift", "Node")

    # CLI results (files with cli_ prefix)
    cli_mds = sorted(f for f in RESULTS_DIR.glob("cli_*.md"))
    cli_jsons = sorted(f for f in RESULTS_DIR.glob("cli_*.json"))
    if cli_mds:
        lines.append("# CLI Benchmark (Swift CLI vs idb)")
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
            lines += _speedup_table(cli_jsons, "Swift CLI", "idb")

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
    default="mcp",
    show_default=True,
    help="Benchmark mode: mcp (Swift vs Node MCP), cli (Swift CLI vs idb), or all.",
)
def main(
    swift_bin: str,
    node_server: str,
    idb_path: str,
    warmup: int,
    min_runs: int,
    tools: tuple[str, ...],
    udid: str | None,
    mode: str,
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

    # Check Swift binary
    if not Path(swift_bin).exists():
        warn(f"Swift binary not found at {swift_bin}")
        info("Building release binary...")
        subprocess.run(["swift", "build", "-c", "release"], check=True)

    # MCP-mode prerequisites
    if mode in ("mcp", "all"):
        node_index = node_server.split()[-1]
        if not Path(node_index).exists():
            error(f"Node server not found at {node_index}")
            click.echo(f"  cd {Path(node_index).parent.parent} && npm run build")
            sys.exit(1)
        smoke_test("Swift", swift_bin)
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
            bench(tool, params, udid, swift_bin, node_server, warmup, min_runs)

    # --- CLI benchmarks ---
    if mode in ("cli", "all"):
        cli_tools = CLI_TOOLS
        if tools:
            tool_set = set(tools)
            cli_tools = [(n, s, i) for n, s, i in CLI_TOOLS if n in tool_set]
            if not cli_tools:
                error(f"No matching CLI tools. Available: {', '.join(n for n, _, _ in CLI_TOOLS)}")
                sys.exit(1)
        for name, swift_tpl, idb_tpl in cli_tools:
            swift_full = swift_tpl.format(swift_bin=swift_bin, udid=udid)
            idb_full = idb_tpl.format(idb=idb_path, udid=udid)
            cli_bench(name, swift_full, idb_full, warmup, min_runs)

    # Summary
    summary = generate_summary(
        mode=mode,
        swift_cmd=swift_bin,
        node_cmd=node_server if mode in ("mcp", "all") else None,
        idb_cmd=idb_path if mode in ("cli", "all") else None,
        warmup=warmup,
        min_runs=min_runs,
    )
    summary_path = RESULTS_DIR / "summary.md"
    summary_path.write_text(summary)

    info(f"Results saved to {RESULTS_DIR}/")
    info(f"Summary written to {summary_path}")
    click.echo()
    # click.echo(summary)


if __name__ == "__main__":
    main()
