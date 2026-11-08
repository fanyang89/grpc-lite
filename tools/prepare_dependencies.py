#!/usr/bin/env python3
"""Prepare the complete pinned Zig dependency closure using verified local fetches."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tarfile
import time
import zipfile


def unpack(archive, destination):
    destination.mkdir()
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                target = (destination / member.filename).resolve()
                if not target.is_relative_to(destination.resolve()):
                    raise ValueError(f"unsafe archive entry: {member.filename}")
                bundle.extract(member, destination)
                if not member.is_dir() and member.create_system == 3:
                    target.chmod((member.external_attr >> 16) & 0o777)
    else:
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
    entries = list(destination.iterdir())
    return entries[0] if len(entries) == 1 and entries[0].is_dir() else destination


def dependencies(manifest):
    # Parse only the flat dependency records used by Zig manifests. Reject any
    # unsupported syntax instead of silently omitting part of the closure.
    text = re.sub(
        r'"(?:\\.|[^"\\])*"|//[^\n]*',
        lambda m: "" if m[0].startswith("//") else m[0],
        manifest.read_text(),
    )
    start = re.search(r"\.dependencies\s*=\s*\.\{", text)
    if start is None:
        if re.search(r"\.dependencies\s*=", text):
            raise ValueError(f"unsupported dependencies in {manifest}")
        return []
    depth, end = 1, start.end()
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|[{}]', text[end:]):
        if token[0] == "{":
            depth += 1
        elif token[0] == "}":
            depth -= 1
        if depth == 0:
            end += token.start()
            break
    else:
        raise ValueError(f"unclosed dependencies in {manifest}")
    body = text[start.end() : end]
    entry = re.compile(
        r'\s*\.(?:@"(?:\\.|[^"\\])*"|\w+)\s*=\s*\.\{([^{}]*)\}\s*,?', re.S
    )
    field = re.compile(r'\s*\.(\w+)\s*=\s*("(?:\\.|[^"\\])*"|true|false)\s*,?')
    result, pos = [], 0
    while body[pos:].strip():
        match = entry.match(body, pos)
        if match is None:
            raise ValueError(
                f"unsupported dependency syntax in {manifest}: {body[pos : pos + 100]}"
            )
        values, offset = {}, 0
        while match[1][offset:].strip():
            item = field.match(match[1], offset)
            if item is None or item[1] in values:
                raise ValueError(f"unsupported dependency fields in {manifest}")
            values[item[1]] = json.loads(item[2])
            offset = item.end()
        if set(values) - {"url", "hash", "path", "lazy"}:
            raise ValueError(f"unknown dependency fields in {manifest}")
        if "path" not in values and not {"url", "hash"} <= values.keys():
            raise ValueError(f"unpinned dependency in {manifest}")
        result.append(values)
        pos = match.end()
    return result


def download(url, destination):
    # Use GitHub's archive origin without changing package contents or hashes.
    url = re.sub(
        r"https://github.com/([^/]+/[^/]+)/archive/(.+)\.tar\.gz$",
        r"https://codeload.github.com/\1/tar.gz/\2",
        url,
    )
    for attempt in range(5):
        result = subprocess.run(
            [
                "curl",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--connect-timeout",
                "15",
                "--max-time",
                "120",
                "--write-out",
                "%{http_code}",
                "--output",
                str(destination),
                url,
            ],
            text=True,
            capture_output=True,
        )
        if result.returncode == 0:
            return
        transient = result.returncode in {5, 6, 7, 18, 28, 35, 52, 55, 56} or (
            result.returncode == 22
            and result.stdout in {"408", "429", "500", "502", "503", "504"}
        )
        if not transient or attempt == 4:
            raise RuntimeError(f"download failed: {url}: {result.stderr}")
        print(f"Transient download failure; retry {attempt + 1}/4: {url}", flush=True)
        time.sleep(2**attempt)


def prepare(root, store):
    store.mkdir(parents=True, exist_ok=True)
    visited = set()
    with tempfile.TemporaryDirectory(prefix="verify-", dir=store) as temporary:
        temporary = Path(temporary)
        env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(temporary / "global"))
        env.pop("ZIG_LOCAL_PKG_DIR", None)

        def visit(manifest):
            for dep in dependencies(manifest):
                if "path" in dep:
                    nested = (manifest.parent / dep["path"] / "build.zig.zon").resolve()
                    if nested not in visited:
                        visited.add(nested)
                        visit(nested)
                    continue
                digest = dep["hash"]
                if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]+", digest):
                    raise ValueError(f"invalid package hash: {digest}")
                if digest in visited:
                    continue
                visited.add(digest)
                archive = store / (
                    digest + (".zip" if dep["url"].endswith(".zip") else ".tar.gz")
                )
                candidate = archive
                if not archive.exists():
                    candidate = temporary / archive.name
                    print(f"Downloading {dep['url']}", flush=True)
                    download(dep["url"], candidate)
                # Zig verifies package contents locally; neither hash failures nor
                # malformed archives are retried. Never patch dependency sources.
                source = unpack(candidate, temporary / (digest + "-source"))
                result = subprocess.run(
                    ["zig", "fetch", str(source)],
                    env=env,
                    text=True,
                    capture_output=True,
                )
                if result.returncode:
                    raise RuntimeError(
                        f"zig fetch failed for {dep['url']}: {result.stderr}"
                    )
                actual = result.stdout.strip()
                if actual != digest:
                    raise ValueError(
                        f"package hash mismatch: expected {digest}, got {actual}"
                    )
                if candidate != archive:
                    candidate.replace(archive)
                nested = source / "build.zig.zon"
                if nested.exists():
                    visit(nested)

        visit(root / "build.zig.zon")
        # Only publish the complete, verified canonical cache. Zig itself creates
        # these archives, including the correct root layout and executable bits.
        output = store / "p"
        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(temporary / "global" / "p", output)
    print(
        f"Prepared {sum(isinstance(item, str) for item in visited)} verified packages",
        flush=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--store", type=Path, default=Path(".zig-cache/dependencies"))
    args = parser.parse_args()
    prepare(args.root.resolve(), args.store.resolve())
