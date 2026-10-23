#!/usr/bin/env python3
"""Check source release versions; packaging owns generated-manifest validation."""

import argparse
from pathlib import Path
import re


VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"


def read_single_version(root, name, pattern):
    values = re.findall(pattern, (root / name).read_text(encoding="utf-8"), re.MULTILINE)
    if len(values) != 1 or not re.fullmatch(VERSION, values[0]):
        raise ValueError(f"Expected exactly one numeric release version in {name}")
    return values[0]


def check_release_version(root, tag=None):
    versions = {
        name: read_single_version(root, name, pattern)
        for name, pattern in (
            ("build.zig.zon", r'^\s*\.version = "([^"]*)",$'),
            ("CMakeLists.txt", r"^project\(grpc_lite VERSION ([^ ]*) LANGUAGES C\)$"),
            ("cmake/grpc_liteConfigVersion.cmake", r'^set\(PACKAGE_VERSION "([^"]*)"\)$'),
        )
    }
    version = versions["build.zig.zon"]
    for name, actual in versions.items():
        if actual != version:
            raise ValueError(f"Version mismatch: {name}={actual}, build.zig.zon={version}")

    # Match concrete bundle names/paths, not dependency versions or <version> templates.
    bundle_pattern = r"grpc-lite-transpiled-c-([0-9][A-Za-z0-9.+-]*)-linux-(?:x86_64|arm64)"
    for path in [root / "README.md", *sorted((root / "docs").rglob("*.md"))]:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for actual in re.findall(bundle_pattern, line):
                if actual != version:
                    raise ValueError(
                        f"Version mismatch: {path.relative_to(root)}:{line_number} "
                        f"bundle={actual}, build.zig.zon={version}"
                    )

    if tag is not None:
        if not re.fullmatch(f"v{VERSION}", tag):
            raise ValueError(f"Invalid release tag: {tag!r}; expected vMAJOR.MINOR.PATCH")
        if tag != f"v{version}":
            raise ValueError(f"Version mismatch: tag={tag}, build.zig.zon={version}")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="proposed or existing release tag (no Git mutation)")
    args = parser.parse_args()
    try:
        print(check_release_version(Path(__file__).resolve().parent.parent, args.tag))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
