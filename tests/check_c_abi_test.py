#!/usr/bin/env python3
"""Deliberately incompatible fixtures must fail the released-baseline checker."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import check_c_abi as abi


class CAbiTest(unittest.TestCase):
    def setUp(self):
        temporary = Path(os.environ.get("TMPDIR", Path.home() / "tmp")) / "opencode"
        temporary.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="grpc-lite-abi-test-", dir=temporary
        )
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.compiler = shlex.split(os.environ.get("CC", "cc"))
        self.structures, self.functions, self.constants = abi.declarations(
            (abi.BASELINE / "grpc_lite/grpc_lite.h").read_text()
        )
        self.source = abi.probe_source(self.structures, self.functions, self.constants)
        self.baseline = abi.compile_probe(
            self.source, abi.BASELINE, self.work, "baseline", self.compiler
        )
        self.header = (abi.ROOT / "include/grpc_lite/grpc_lite.h").read_text()
        self.include = self.work / "include"
        (self.include / "grpc_lite").mkdir(parents=True)

    def compare(self, header):
        (self.include / "grpc_lite/grpc_lite.h").write_text(header)
        current = abi.compile_probe(
            self.source, self.include, self.work, "current", self.compiler
        )
        abi.compare_layouts(self.baseline, current)

    def test_current_and_additive_options_are_compatible(self):
        self.compare(self.header)
        self.compare(
            self.header.replace(
                "} grpc_lite_channel_options;",
                "  uint64_t future_option;\n} grpc_lite_channel_options;",
            )
        )

    def test_incompatible_header_fixtures(self):
        fixtures = [
            ("major", "GRPC_LITE_ABI_MAJOR 1u", "GRPC_LITE_ABI_MAJOR 2u"),
            (
                "minor rollback",
                re.search(r"GRPC_LITE_ABI_MINOR \d+u", self.header)[0],
                "GRPC_LITE_ABI_MINOR 5u",
            ),
            ("constant", "GRPC_LITE_ERROR_CLOSED = 7", "GRPC_LITE_ERROR_CLOSED = 70"),
            (
                "typedef",
                "typedef int32_t grpc_lite_error;",
                "typedef uint32_t grpc_lite_error;",
            ),
            ("field type", "uint32_t jitter_percent;", "int32_t jitter_percent;"),
            (
                "field offset",
                "  const grpc_lite_logger *logger;",
                "  uint64_t inserted;\n  const grpc_lite_logger *logger;",
            ),
            (
                "frozen size",
                "} grpc_lite_bytes_view;",
                "  uint64_t tail;\n} grpc_lite_bytes_view;",
            ),
            (
                "signature",
                "size_t grpc_lite_metadata_count(",
                "uint32_t grpc_lite_metadata_count(",
            ),
            ("callback", "uint32_t (*on_message)(", "uint64_t (*on_message)("),
            ("removed declaration", "uint32_t grpc_lite_abi_version(void);", ""),
        ]
        for name, before, after in fixtures:
            with self.subTest(name=name):
                self.assertIn(before, self.header)
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    self.compare(self.header.replace(before, after))

    def test_missing_export_and_wrong_soname_are_rejected(self):
        source = self.work / "fixture.c"
        library = self.work / "fixture.so"
        for missing, soname in (
            ("grpc_lite_features", "libgrpc_lite.so.1"),
            (None, "libgrpc_lite.so.2"),
        ):
            with self.subTest(missing=missing, soname=soname):
                source.write_text(
                    "\n".join(
                        f"void {name}(void) {{}}"
                        for name in self.functions
                        if name != missing
                    )
                )
                abi.run(
                    [
                        *self.compiler,
                        "-shared",
                        "-fPIC",
                        str(source),
                        f"-Wl,-soname,{soname}",
                        "-o",
                        str(library),
                    ]
                )
                with self.assertRaisesRegex(
                    ValueError, "missing exported|incompatible SONAME"
                ):
                    abi.check_symbols(library, self.functions, "libgrpc_lite.so.1")

    def test_runtime_header_mismatch_is_rejected(self):
        source = self.work / "stale-version.c"
        library = self.work / "stale-version.so"
        source.write_text(
            "unsigned int grpc_lite_abi_version(void) { return 0x10005; }\n"
            + "\n".join(
                f"void {name}(void) {{}}"
                for name in self.functions
                if name != "grpc_lite_abi_version"
            )
        )
        abi.run(
            [
                *self.compiler,
                "-shared",
                "-fPIC",
                str(source),
                "-Wl,-soname,libgrpc_lite.so.1",
                "-o",
                str(library),
            ]
        )
        with self.assertRaisesRegex(ValueError, "runtime ABI version"):
            abi.check(abi.ROOT / "include", library, self.work)


if __name__ == "__main__":
    unittest.main()
