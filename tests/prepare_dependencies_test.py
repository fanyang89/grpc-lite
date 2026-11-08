#!/usr/bin/env python3
"""Dependency preparation regressions, including real Zig content validation."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "prepare_dependencies",
    Path(__file__).resolve().parents[1] / "tools/prepare_dependencies.py",
)
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)


class DownloadTest(unittest.TestCase):
    def test_connection_reset_and_server_error_retry(self):
        responses = [
            subprocess.CompletedProcess([], 56, "000", "connection reset"),
            subprocess.CompletedProcess([], 22, "503", "unavailable"),
            subprocess.CompletedProcess([], 0, "200", ""),
        ]
        with (
            patch.object(deps.subprocess, "run", side_effect=responses) as run,
            patch.object(deps.time, "sleep") as sleep,
        ):
            deps.download(
                "https://github.com/owner/repo/archive/abc.tar.gz", Path("unused")
            )
        self.assertEqual(run.call_count, 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 2])
        self.assertEqual(
            run.call_args.args[0][-1],
            "https://codeload.github.com/owner/repo/tar.gz/abc",
        )

    def test_permanent_error_is_not_retried(self):
        with patch.object(
            deps.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 22, "404", "not found"),
        ) as run:
            with self.assertRaises(RuntimeError):
                deps.download("https://example.test/missing", Path("unused"))
        self.assertEqual(run.call_count, 1)

    def test_retry_budget_is_bounded(self):
        with (
            patch.object(
                deps.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 28, "000", "timeout"),
            ) as run,
            patch.object(deps.time, "sleep"),
        ):
            with self.assertRaises(RuntimeError):
                deps.download("https://example.test/timeout", Path("unused"))
        self.assertEqual(run.call_count, 5)


@unittest.skipUnless(shutil.which("zig"), "requires the project Zig toolchain")
class ClosureTest(unittest.TestCase):
    def test_transitive_lazy_path_dependencies_cache_and_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(root / "hash-cache"))

            def package(name, dependencies=""):
                source = root / name
                source.mkdir()
                (source / "build.zig.zon").write_text(
                    '.{ .name = .grpc_lite, .version = "0.0.0", .fingerprint = 0xa8480adad018cc05, '
                    '.paths = .{""}, .dependencies = .{' + dependencies + "} }"
                )
                (source / "payload").write_text(name)
                digest = subprocess.check_output(
                    ["zig", "fetch", str(source)], env=env, text=True
                ).strip()
                archive = root / (name + ".tar.gz")
                with tarfile.open(archive, "w:gz") as bundle:
                    bundle.add(source, arcname=name)
                return digest, archive

            def entry(name, digest, archive):
                return f'.{name} = .{{ .url = "{archive.as_uri()}", .hash = "{digest}", .lazy = true }},'

            leaf_hash, leaf_archive = package("leaf")
            parent_hash, parent_archive = package(
                "parent", entry("leaf", leaf_hash, leaf_archive)
            )
            project = root / "project"
            (project / "vendor").mkdir(parents=True)
            (project / "build.zig.zon").write_text(
                '.{ .dependencies = .{ .local = .{ .path = "vendor" } } }'
            )
            (project / "vendor/build.zig.zon").write_text(
                ".{ .dependencies = .{"
                + entry("parent", parent_hash, parent_archive)
                + "} }"
            )
            store = root / "store"
            deps.prepare(project, store)
            self.assertEqual(
                {p.name for p in (store / "p").iterdir()},
                {parent_hash + ".tar.gz", leaf_hash + ".tar.gz"},
            )
            with tarfile.open(store / "p" / (parent_hash + ".tar.gz")) as bundle:
                self.assertIn(parent_hash + "/build.zig.zon", bundle.getnames())
            # A warm cache must not make network calls; it must still revalidate.
            with patch.object(
                deps, "download", side_effect=AssertionError("unexpected network")
            ):
                deps.prepare(project, store)
                shutil.copyfile(parent_archive, store / (leaf_hash + ".tar.gz"))
                with self.assertRaisesRegex(ValueError, "hash mismatch"):
                    deps.prepare(project, store)


class ManifestTest(unittest.TestCase):
    def test_unsupported_fields_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "build.zig.zon"
            manifest.write_text(
                '.{ .dependencies = .{ .thing = .{ .url = "https://example.test/a", .hash = "abc", .unknown = true } } }'
            )
            with self.assertRaisesRegex(ValueError, "unknown dependency fields"):
                deps.dependencies(manifest)


if __name__ == "__main__":
    unittest.main()
