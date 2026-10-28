#!/usr/bin/env python3
"""Offline regression for check_release_version.py and its packaging entry point."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parent.parent


class CheckReleaseVersionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="grpc-lite-release-version-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in (
            "build.zig.zon",
            "CMakeLists.txt",
            "cmake/grpc_liteConfigVersion.cmake",
            "README.md",
            "tools/check_release_version.py",
            "tools/package_transpiled_c.sh",
            "tools/transpiled_c_target.sh",
        ):
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT_ROOT / name, dest)
        shutil.copytree(PROJECT_ROOT / "docs", self.root / "docs")
        self.version = self.check().stdout.strip()

    def run_command(self, *args, env=None):
        return subprocess.run(
            args, cwd=self.root, env=env, text=True, capture_output=True
        )

    def check(self, *args):
        return self.run_command(
            sys.executable, str(self.root / "tools/check_release_version.py"), *args
        )

    def replace(self, name, old, new, count=-1):
        path = self.root / name
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, count), encoding="utf-8")

    def assert_rejected(self, result, diagnostic):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(diagnostic, result.stderr)

    def test_valid_source_and_proposed_tag(self):
        for args in ((), ("--tag", f"v{self.version}")):
            with self.subTest(args=args):
                result = self.check(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), self.version)

    def test_coordinated_candidate_version_update(self):
        for name in (
            "build.zig.zon",
            "CMakeLists.txt",
            "cmake/grpc_liteConfigVersion.cmake",
            "README.md",
            "docs/c-cpp-reference.md",
        ):
            self.replace(name, self.version, "999.0.0")
        result = self.check("--tag", "v999.0.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "999.0.0")

    def test_each_metadata_mismatch(self):
        for name in (
            "build.zig.zon",
            "CMakeLists.txt",
            "cmake/grpc_liteConfigVersion.cmake",
        ):
            with self.subTest(name=name):
                self.replace(name, self.version, "999.0.0", 1)
                self.assert_rejected(self.check(), "Version mismatch")
                self.replace(name, "999.0.0", self.version, 1)

    def test_missing_duplicate_and_malformed_metadata(self):
        path = self.root / "build.zig.zon"
        original = path.read_text(encoding="utf-8")
        declaration = f'.version = "{self.version}",'
        for text in (
            original.replace(declaration, ""),
            original + f"\n{declaration}\n",
            original.replace(declaration, '.version = "not-a-version",'),
        ):
            with self.subTest(text=text):
                path.write_text(text, encoding="utf-8")
                self.assert_rejected(
                    self.check(), "Expected exactly one numeric release version"
                )

    def test_documentation_mismatch_including_one_stale_example(self):
        for name in ("README.md", "docs/c-cpp-reference.md"):
            with self.subTest(name=name):
                self.replace(
                    name,
                    f"grpc-lite-transpiled-c-{self.version}",
                    "grpc-lite-transpiled-c-999.0.0",
                    1,
                )
                self.assert_rejected(self.check(), f"Version mismatch: {name}:")
                self.replace(
                    name,
                    "grpc-lite-transpiled-c-999.0.0",
                    f"grpc-lite-transpiled-c-{self.version}",
                    1,
                )

    def test_new_documentation_arm64_mismatch(self):
        (self.root / "docs/new.md").write_text(
            "grpc-lite-transpiled-c-999.0.0-linux-arm64.tar.gz\n", encoding="utf-8"
        )
        self.assert_rejected(self.check(), "Version mismatch: docs/new.md:1")

    def test_tag_mismatch_and_invalid_tag(self):
        self.assert_rejected(self.check("--tag", "v999.0.0"), "Version mismatch: tag=")
        for tag in (self.version, f"v{self.version}-rc1", "v1.2", ""):
            with self.subTest(tag=tag):
                self.assert_rejected(self.check("--tag", tag), "Invalid release tag")

    def prepare_package_fixture(self):
        # Stub only generation/toolchain: exercise the real packager's manifest,
        # metadata, archive layout, and checksum checks without compiling Zig.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        required_zig = next(
            line.split('"')[1]
            for line in (self.root / "build.zig.zon").read_text().splitlines()
            if ".minimum_zig_version =" in line
        )
        (bin_dir / "zig").write_text(f"#!/bin/sh\necho {required_zig}\n")
        (bin_dir / "zig").chmod(0o755)
        generator = self.root / "tools/transpile_c.sh"
        generator.write_text("""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
out = pathlib.Path(sys.argv[1])
for name in ("include/zig.h", "src/grpc_lite.c", "src/protoc-gen-grpc_lite_cpp.c"):
    path = out / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("fixture\\n")
def git(*args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
version = next(line.split('"')[1] for line in
               (root / "build.zig.zon").read_text().splitlines() if ".version =" in line)
manifest = {
    "schema_version": 1,
    "project_version": os.environ.get("FIXTURE_PROJECT_VERSION", version),
    "source_commit": git("rev-parse", "HEAD"),
    "dirty": bool(git("status", "--porcelain")),
    "zig_version": subprocess.check_output(["zig", "version"], text=True).strip(),
    "target": os.environ["GRPC_LITE_TRANSPILED_C_TARGET"],
    "optimization": "ReleaseSafe",
    "tls": False,
}
(out / "manifest.json").write_text(json.dumps(manifest))
""")
        generator.chmod(0o755)
        (self.root / ".gitignore").write_text("/dist/\n")
        for args in (
            ("init", "-q"),
            ("add", "."),
            (
                "-c",
                "user.name=Release Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ),
        ):
            result = self.run_command("git", *args)
            self.assertEqual(result.returncode, 0, result.stderr)
        return dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            GRPC_LITE_TRANSPILED_C_TARGET="x86_64-linux-gnu",
        )

    def package(self, env):
        return self.run_command(
            "bash", "tools/package_transpiled_c.sh", "dist", env=env
        )

    def test_package_valid_and_manifest_mismatch(self):
        env = self.prepare_package_fixture()
        result = self.package(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list((self.root / "dist").glob("*.tar.gz"))
        self.assertEqual(len(archives), 1)
        with tarfile.open(archives[0]) as archive:
            manifest = json.load(
                archive.extractfile(
                    f"grpc-lite-transpiled-c-{self.version}-linux-x86_64/manifest.json"
                )
            )
        self.assertEqual(manifest["project_version"], self.version)
        shutil.rmtree(self.root / "dist")
        env["FIXTURE_PROJECT_VERSION"] = "999.0.0"
        self.assert_rejected(self.package(env), "manifest mismatch")
        self.assertEqual(list((self.root / "dist").glob("*.tar.gz")), [])

    def test_package_rejects_source_mismatch_before_generation(self):
        env = self.prepare_package_fixture()
        (self.root / "tools/transpile_c.sh").write_text(
            '#!/bin/sh\necho "Unexpected generation" >&2\nexit 99\n'
        )
        for name in ("CMakeLists.txt", "README.md"):
            with self.subTest(name=name):
                self.replace(name, self.version, "999.0.0", 1)
                self.assert_rejected(self.package(env), "Version mismatch")
                self.assertEqual(list((self.root / "dist").glob("*.tar.gz")), [])
                self.replace(name, "999.0.0", self.version, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
