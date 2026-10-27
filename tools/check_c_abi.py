#!/usr/bin/env python3
"""Check the released grpc-lite C ABI using the host C compiler and ELF tools."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "tests/consumer/abi/baseline"
EXTENSIBLE = {"grpc_lite_channel_options", "grpc_lite_server_options"}


def run(command):
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout


def declarations(header):
    """Read the fixed baseline's simple declarations, not arbitrary C syntax.

    The compiler, rather than this parser, checks types and computes layouts.
    A baseline update must review this inventory and its counts in provenance.json.
    """
    text = re.sub(r"/\*.*?\*/", "", header, flags=re.S)
    structures = {}
    for name, body in re.findall(r"typedef struct (\w+) \{(.*?)\} \1;", text, re.S):
        fields = {}
        for declaration in body.split(";"):
            declaration = declaration.strip()
            if not declaration:
                continue
            callback = re.search(r"\(\*(\w+)\)", declaration)
            if callback:
                field = callback[1]
                field_type = declaration.replace(f"(*{field})", "(*)", 1)
            else:
                match = re.fullmatch(r"(.+?)(\w+)", declaration, re.S)
                if not match:
                    raise ValueError(f"unsupported baseline field: {declaration}")
                field_type, field = match.groups()
            fields[field] = field_type.strip()
        structures[name] = fields
    functions = {}
    for result, name, parameters in re.findall(
        r"^((?:const\s+)?\w+\s*\*?\s+|(?:const\s+)?\w+\s*\*)"
        r"(grpc_lite_\w+)\s*\(([^;]*)\);",
        text,
        re.M,
    ):
        functions[name] = f"{result.strip()} (*)({parameters})"
    constants = set(re.findall(r"\b(GRPC_LITE_\w+)\s*=", text))
    constants.update(re.findall(r"^#define (GRPC_LITE_FEATURE_\w+)\b", text, re.M))
    constants.update(
        {"GRPC_LITE_ABI_MAJOR", "GRPC_LITE_ABI_MINOR", "GRPC_LITE_ABI_VERSION"}
    )
    return structures, functions, sorted(constants)


def probe_source(structures, functions, constants):
    lines = ["#include <grpc_lite/grpc_lite.h>", "#include <stdio.h>"]
    for name, underlying in (
        ("grpc_lite_error", "int32_t"),
        ("grpc_lite_feature_bits", "uint64_t"),
    ):
        lines.append(
            f"_Static_assert(__builtin_types_compatible_p({name}, {underlying}), "
            f'"typedef: {name}");'
        )
    for name, signature in functions.items():
        lines.append(
            f"_Static_assert(__builtin_types_compatible_p(__typeof__(&{name}), "
            f'{signature}), "signature: {name}");'
        )
    for name, fields in structures.items():
        for field, field_type in fields.items():
            lines.append(
                f"_Static_assert(__builtin_types_compatible_p("
                f"__typeof__((({name} *)0)->{field}), {field_type}), "
                f'"field type: {name}.{field}");'
            )
    lines.append("int main(void) {")
    expressions = {name: name for name in constants}
    for name, fields in structures.items():
        expressions[f"{name}.size"] = f"sizeof({name})"
        expressions[f"{name}.align"] = f"_Alignof({name})"
        for field in fields:
            expressions[f"{name}.{field}.offset"] = f"offsetof({name}, {field})"
            expressions[f"{name}.{field}.size"] = f"sizeof((({name} *)0)->{field})"
    for key, expression in expressions.items():
        lines.append(f'printf("{key}=%llu\\n", (unsigned long long)({expression}));')
    lines.append("return 0; }")
    return "\n".join(lines)


def compile_probe(source, include, work, name, compiler):
    path = work / f"{name}.c"
    path.write_text(source)
    executable = work / name
    run(
        [
            *compiler,
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            str(include),
            str(path),
            "-o",
            str(executable),
        ]
    )
    return {
        key: int(value)
        for key, value in (
            line.split("=") for line in run([str(executable)]).splitlines()
        )
    }


def compare_layouts(baseline, current):
    for key, expected in baseline.items():
        actual = current[key]
        if key == "GRPC_LITE_ABI_MINOR":
            compatible = expected <= actual <= 0xFFFF
        elif key == "GRPC_LITE_ABI_VERSION":
            compatible = actual == (
                (current["GRPC_LITE_ABI_MAJOR"] << 16) | current["GRPC_LITE_ABI_MINOR"]
            )
        elif key.endswith(".size") and key[:-5] in EXTENSIBLE:
            compatible = actual >= expected
        else:
            compatible = actual == expected
        if not compatible:
            raise ValueError(
                f"incompatible {key}: baseline={expected}, current={actual}"
            )


def check_symbols(library, functions, soname):
    symbols = set()
    for line in run(["nm", "-D", "--defined-only", str(library)]).splitlines():
        columns = line.split()
        if len(columns) >= 3 and columns[-2] in {"T", "W"}:
            symbols.add(columns[-1].split("@")[0])
    missing = sorted(set(functions) - symbols)
    if missing:
        raise ValueError(f"missing exported functions: {', '.join(missing)}")
    dynamic = run(["readelf", "-d", str(library)])
    if not re.search(r"\(SONAME\).*\[" + re.escape(soname) + r"\]", dynamic):
        raise ValueError(f"incompatible SONAME: expected {soname}")


def check(include, library, work):
    provenance = json.loads((BASELINE / "provenance.json").read_text())
    header = BASELINE / "grpc_lite/grpc_lite.h"
    if hashlib.sha256(header.read_bytes()).hexdigest() != provenance["snapshot_sha256"]:
        raise ValueError("baseline header checksum mismatch")
    structures, functions, constants = declarations(header.read_text())
    inventory = {
        "structures": len(structures),
        "fields": sum(map(len, structures.values())),
        "functions": len(functions),
        "constants": len(constants),
    }
    if inventory != provenance["inventory"]:
        raise ValueError(f"baseline declaration inventory mismatch: {inventory}")
    compiler = shlex.split(os.environ.get("CC", "cc"))
    source = probe_source(structures, functions, constants)
    baseline = compile_probe(source, BASELINE, work, "baseline-layout", compiler)
    current = compile_probe(source, include, work, "current-layout", compiler)
    compare_layouts(baseline, current)
    check_symbols(library, functions, provenance["soname"])
    runtime = ctypes.CDLL(str(library))
    runtime.grpc_lite_abi_version.restype = ctypes.c_uint32
    if runtime.grpc_lite_abi_version() != current["GRPC_LITE_ABI_VERSION"]:
        raise ValueError("runtime ABI version does not match the current header")
    print(
        f"C ABI compatible with {provenance['release']} (ABI "
        f"{baseline['GRPC_LITE_ABI_MAJOR']}.{baseline['GRPC_LITE_ABI_MINOR']}): "
        f"{len(functions)} exports, {len(structures)} structures"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--include", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    args = parser.parse_args()
    temporary = Path(os.environ.get("TMPDIR", Path.home() / "tmp")) / "opencode"
    temporary.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(
            prefix="grpc-lite-abi-", dir=temporary
        ) as work:
            check(args.include.resolve(), args.library.resolve(), Path(work))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"C ABI check failed: {error}\n{getattr(error, 'stderr', '')}")


if __name__ == "__main__":
    main()
