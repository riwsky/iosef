#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["click"]
# ///
"""Build a Python wheel that wraps the iosef binary for PyPI distribution.

Produces a wheel with the structure:
    iosef/__init__.py        (thin os.execvp wrapper)
    iosef/bin/iosef          (the Swift binary)
    iosef-{ver}.dist-info/   (METADATA, WHEEL, entry_points.txt, RECORD)
"""

import hashlib
import io
import os
import re
import subprocess
import zipfile
from base64 import urlsafe_b64encode
from pathlib import Path

import click


def _sha256_digest(data: bytes) -> str:
    return urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def _record_line(path: str, data: bytes) -> str:
    return f"{path},sha256={_sha256_digest(data)},{len(data)}"


def _detect_archs(binary: Path) -> list[str]:
    """Detect architectures in a Mach-O binary using `lipo -archs`."""
    r = subprocess.run(
        ["lipo", "-archs", str(binary)], capture_output=True, text=True
    )
    if r.returncode != 0:
        raise click.ClickException(f"lipo -archs failed: {r.stderr.strip()}")
    return r.stdout.strip().split()


def _platform_tag(archs: list[str]) -> str:
    """Determine the wheel platform tag from binary architectures."""
    arch_set = set(archs)
    if arch_set == {"arm64", "x86_64"} or arch_set >= {"arm64", "x86_64"}:
        return "macosx_11_0_universal2"
    elif arch_set == {"arm64"}:
        return "macosx_11_0_arm64"
    elif arch_set == {"x86_64"}:
        return "macosx_13_0_x86_64"
    else:
        raise click.ClickException(
            f"Unsupported architecture(s): {', '.join(sorted(arch_set))}"
        )


INIT_PY = """\
import os
import stat
import sys


def main():
    binary = os.path.join(os.path.dirname(__file__), "bin", "iosef")
    current_mode = os.stat(binary).st_mode
    if not (current_mode & stat.S_IXUSR):
        os.chmod(binary, current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    os.execvp(binary, [binary] + sys.argv[1:])
"""


def build_wheel(binary: Path, version: str, output_dir: Path) -> Path:
    archs = _detect_archs(binary)
    platform_tag = _platform_tag(archs)
    click.echo(f"Detected architectures: {', '.join(archs)} -> {platform_tag}")

    wheel_name = f"iosef-{version}-py3-none-{platform_tag}.whl"
    wheel_path = output_dir / wheel_name
    output_dir.mkdir(parents=True, exist_ok=True)

    dist_info = f"iosef-{version}.dist-info"
    record_entries: list[str] = []

    # Read the README for long description
    readme_path = binary.resolve().parent.parent.parent / "README.md"
    if not readme_path.exists():
        readme_path = Path.cwd() / "README.md"
    long_description = readme_path.read_text() if readme_path.exists() else ""

    metadata = (
        "Metadata-Version: 2.1\n"
        f"Name: iosef\n"
        f"Version: {version}\n"
        "Summary: CLI and MCP server for iOS Simulator automation, designed for agents\n"
        "Home-page: https://github.com/riwsky/iosef\n"
        "Author: Will Cybriwsky\n"
        "License: MIT\n"
        "Classifier: Development Status :: 4 - Beta\n"
        "Classifier: Environment :: Console\n"
        "Classifier: Intended Audience :: Developers\n"
        "Classifier: License :: OSI Approved :: MIT License\n"
        "Classifier: Operating System :: MacOS\n"
        "Classifier: Topic :: Software Development :: Testing\n"
        "Requires-Python: >=3.8\n"
        "Description-Content-Type: text/markdown\n"
        "\n"
        f"{long_description}"
    )

    wheel_metadata = (
        "Wheel-Version: 1.0\n"
        "Generator: iosef-build-wheel\n"
        "Root-Is-Purelib: false\n"
        f"Tag: py3-none-{platform_tag}\n"
    )

    entry_points = "[console_scripts]\niosef = iosef:main\n"

    binary_data = binary.read_bytes()
    init_data = INIT_PY.encode()
    metadata_data = metadata.encode()
    wheel_data = wheel_metadata.encode()
    entry_points_data = entry_points.encode()

    with zipfile.ZipFile(wheel_path, "w", compression=zipfile.ZIP_DEFLATED) as whl:
        # __init__.py
        whl.writestr("iosef/__init__.py", init_data)
        record_entries.append(_record_line("iosef/__init__.py", init_data))

        # Binary — store uncompressed to preserve executable bits and avoid
        # decompression overhead on a large file
        info = zipfile.ZipInfo("iosef/bin/iosef")
        info.compress_type = zipfile.ZIP_STORED
        # Set external_attr for unix rwxr-xr-x (0o755)
        info.external_attr = 0o100755 << 16
        whl.writestr(info, binary_data)
        record_entries.append(_record_line("iosef/bin/iosef", binary_data))

        # dist-info/METADATA
        whl.writestr(f"{dist_info}/METADATA", metadata_data)
        record_entries.append(
            _record_line(f"{dist_info}/METADATA", metadata_data)
        )

        # dist-info/WHEEL
        whl.writestr(f"{dist_info}/WHEEL", wheel_data)
        record_entries.append(_record_line(f"{dist_info}/WHEEL", wheel_data))

        # dist-info/entry_points.txt
        whl.writestr(f"{dist_info}/entry_points.txt", entry_points_data)
        record_entries.append(
            _record_line(f"{dist_info}/entry_points.txt", entry_points_data)
        )

        # dist-info/RECORD (self-entry has no hash)
        record_entries.append(f"{dist_info}/RECORD,,")
        record_data = "\n".join(record_entries) + "\n"
        whl.writestr(f"{dist_info}/RECORD", record_data)

    return wheel_path


@click.command()
@click.argument("binary", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option(
    "--version",
    required=True,
    help="Wheel version (e.g. 3.0.0). Typically extracted from git tag.",
)
@click.option(
    "--output-dir",
    "-o",
    default="dist",
    type=click.Path(path_type=Path),
    show_default=True,
    help="Directory to write the wheel into.",
)
def main(binary: Path, version: str, output_dir: Path) -> None:
    """Package a pre-built iosef binary into a Python wheel for PyPI."""
    if not re.match(r"^\d+\.\d+\.\d+", version):
        raise click.ClickException(
            f"Version must be semver-like (e.g. 3.0.0), got: {version}"
        )

    wheel_path = build_wheel(binary, version, output_dir)
    click.echo(f"Built wheel: {wheel_path}")
    click.echo(f"  Size: {wheel_path.stat().st_size / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
