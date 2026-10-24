"""Exercise the real shell entrypoint with isolated Docker and client fixtures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CASES = (
    "data_frame_padding",
    "goaway",
    "max_streams",
    "no_df_padding_sanity_test",
    "ping",
    "rst_after_data",
    "rst_after_header",
    "rst_during_data",
)


class Http2EdgeRunnerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        official = self.root / "tests/official"
        official.mkdir(parents=True)
        (official / "run_http2_edge.sh").write_text(
            Path(__file__).with_name("run_http2_edge.sh").read_text()
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_executable(self.bin / "zig", "#!/bin/bash\nexit 0\n")
        self.write_executable(self.bin / "sleep", "#!/bin/bash\n/bin/sleep 0.001\n")
        self.write_executable(
            self.bin / "docker",
            r"""#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FIXTURE_ROOT/docker.log"
command=$1
shift
case "$command" in
  build) printf 'fixture-image\n' ;;
  run)
    if [[ ${FIXTURE_STARTUP_FAILURE:-0} == 1 ]]; then
      printf 'fixture startup failed\n'
      exit 1
    fi
    touch "$FIXTURE_ROOT/running"
    while [[ ! -e "$FIXTURE_ROOT/stopped" ]]; do /bin/sleep 0.01; done
    ;;
  exec)
    [[ -e "$FIXTURE_ROOT/running" && ${FIXTURE_NOT_READY:-0} == 0 ]]
    ;;
  port)
    if [[ ${FIXTURE_BAD_MAPPING:-0} == 1 ]]; then
      printf '0.0.0.0:45000\n'
    else
      internal=${2%/tcp}
      printf '127.0.0.1:%s\n' "$((45000 + (internal - 40000) * 2))"
    fi
    ;;
  stop) touch "$FIXTURE_ROOT/stopped" ;;
  *) exit 90 ;;
esac
""",
        )
        client = self.root / "zig-out/bin/grpc-lite-interop-client"
        client.parent.mkdir(parents=True)
        self.write_executable(
            client,
            r"""#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FIXTURE_ROOT/client.log"
exit "${FIXTURE_CLIENT_EXIT:-0}"
""",
        )

    @staticmethod
    def write_executable(path, source):
        path.write_text(source)
        path.chmod(0o755)

    def run_fixture(self, **overrides):
        env = dict(os.environ)
        env.pop("HTTP2_EDGE_BASE_PORT", None)
        env.update(PATH=f"{self.bin}:{env['PATH']}", FIXTURE_ROOT=str(self.root))
        env.update(overrides)
        return subprocess.run(
            ["bash", str(self.root / "tests/official/run_http2_edge.sh")],
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
        )

    def docker_log(self):
        return (self.root / "docker.log").read_text()

    def test_dynamic_loopback_mappings_drive_every_case(self):
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.docker_log()
        self.assertIn("--network bridge", log)
        self.assertNotIn("--network host", log)
        self.assertIn("--host=0.0.0.0 --base_port=40000", log)
        self.assertIn("/proc/net/tcp", log)
        for index, case in enumerate(CASES):
            self.assertIn(f"--publish 127.0.0.1::{40000 + index}/tcp", log)
            self.assertIn(
                f"--server_host=127.0.0.1 --server_port={45000 + index * 2} "
                f"--test_case={case} --use_tls=false",
                (self.root / "client.log").read_text(),
            )
        self.assertEqual(len((self.root / "client.log").read_text().splitlines()), 8)
        self.assertTrue((self.root / "stopped").exists())

    def test_fixed_host_base_override(self):
        result = self.run_fixture(HTTP2_EDGE_BASE_PORT="42000")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for index in range(8):
            self.assertIn(
                f"--publish 127.0.0.1:{42000 + index}:{40000 + index}/tcp",
                self.docker_log(),
            )

    def test_invalid_fixed_base_fails_before_build(self):
        for value in ("0", "01", "-1", "65529", "65536", "999999999999", "bad"):
            with self.subTest(value=value):
                result = self.run_fixture(HTTP2_EDGE_BASE_PORT=value)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse((self.root / "docker.log").exists())

    def test_unready_backend_never_starts_cases(self):
        result = self.run_fixture(FIXTURE_NOT_READY="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("timed out waiting", result.stderr)
        self.assertFalse((self.root / "client.log").exists())
        self.assertTrue((self.root / "stopped").exists())

    def test_startup_failure_is_not_a_passing_suite(self):
        result = self.run_fixture(FIXTURE_STARTUP_FAILURE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("fixture startup failed", result.stderr)
        self.assertFalse((self.root / "client.log").exists())

    def test_non_loopback_mapping_fails_and_cleans_up(self):
        result = self.run_fixture(FIXTURE_BAD_MAPPING="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("invalid loopback port mapping", result.stderr)
        self.assertFalse((self.root / "client.log").exists())
        self.assertTrue((self.root / "stopped").exists())

    def test_client_failure_is_preserved_and_cleans_up(self):
        result = self.run_fixture(FIXTURE_CLIENT_EXIT="23")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("[ FAIL ] data_frame_padding", result.stderr)
        self.assertTrue((self.root / "stopped").exists())


if __name__ == "__main__":
    unittest.main()
