"""Static/synthetic observer tests; no Zig/Go build or gRPC traffic."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import unittest
from unittest.mock import patch

import streaming_soak_resources as resources


class Clock:
    now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Child:
    pid = 123

    def __init__(self, clock, end=10, status=0):
        self.clock, self.end, self.status = clock, end, status
        self.terminated = False

    def poll(self):
        return self.status if self.clock.now >= self.end or self.terminated else None

    def wait(self, timeout=None):
        return self.status

    def terminate(self):
        self.terminated = True


class StreamingSoakResourcesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def observe(self, end=10, status=0, missing=False):
        clock = Clock()
        child = Child(clock, end, status)
        metrics = {"rss_kib": 1024, "fds": 5, "threads": 2}
        with patch.object(resources.time, "monotonic", clock.monotonic), \
                patch.object(resources.time, "sleep", clock.sleep), \
                patch.object(resources.subprocess, "Popen", return_value=child), \
                patch.object(resources, "identity", return_value="42"), \
                patch.object(resources, "sample", side_effect=FileNotFoundError() if missing else None, return_value=metrics):
            status = resources.observe(self.directory, 456, 10, 47, ["synthetic"])
        return status, json.loads((self.directory / "resources-summary.json").read_text()), child

    def test_current_process_metrics_and_identity(self):
        pid = os.getpid()
        metrics = resources.sample(pid, resources.identity(pid))
        self.assertTrue(all(metrics[key] > 0 for key in resources.METRICS))
        with self.assertRaises(ValueError):
            resources.sample(pid, "wrong-start-time")

    def test_missing_proc_fields_not_zero(self):
        proc = self.directory / "1"
        proc.mkdir()
        (proc / "stat").write_text("1 (name ) with spaces) S " + "0 " * 18 + "42\n")
        (proc / "status").write_text("Threads: 2\n")
        (proc / "fd").mkdir()
        self.assertEqual(resources.identity(1, self.directory), "42")
        with self.assertRaises(KeyError):
            resources.sample(1, "42", self.directory)

    def test_short_run_reports_phases_not_baseline_claim(self):
        status, report, _ = self.observe()
        self.assertEqual(status, 0)
        self.assertEqual(report["screen"], "short_run")
        server = report["comparisons"][0]
        self.assertTrue(all(server["phases"][phase]["count"] for phase in ("baseline", "warmup", "steady", "teardown")))
        self.assertEqual(report["comparisons"][1]["phases"]["teardown"]["count"], 0)
        self.assertIn("client_teardown", report["unavailable"])
        self.assertLess((self.directory / "resources.jsonl").stat().st_size, 1024 * 1024)

    def test_timeout_reports_and_reaps_child(self):
        status, report, child = self.observe(end=1000)
        self.assertEqual(status, 1)
        self.assertIn("client observation timeout", report["errors"])
        self.assertTrue(child.terminated)
        self.assertLess(report["samples"], 2 * resources.MAX_TICKS + 11)

    def test_failed_client_cannot_pass(self):
        status, report, _ = self.observe(end=1, status=7)
        self.assertEqual(status, 1)
        self.assertEqual(report["client_exit"], 7)
        self.assertIn("client failed", report["errors"])

    def test_missing_process_data_cannot_pass(self):
        status, report, _ = self.observe(missing=True)
        self.assertEqual(status, 1)
        self.assertEqual(report["screen"], "incomplete")
        row = json.loads((self.directory / "resources.jsonl").read_text())
        self.assertIn("unavailable", row)
        self.assertNotIn("rss_kib", row)

    def test_growth_alert_is_not_called_a_leak(self):
        rows = []
        for role in ("server", "client"):
            for index in range(30):
                rows.append({"role": role, "phase": "baseline" if index == 0 else "teardown" if index >= 27 else "steady",
                             "rss_kib": 1024 if index < 10 else 200000, "fds": 5 if index < 10 else 20, "threads": 2})
        report = resources.compare(rows, 600)
        self.assertEqual(report["screen"], "growth_alert")
        self.assertTrue(any(not check["ok"] for item in report["comparisons"] for check in item["checks"]))
        self.assertEqual(resources.compare([], 600)["screen"], "incomplete")

    def test_stale_success_and_failed_harness_reporting(self):
        path = self.directory / "resources-summary.json"
        path.write_text('{"status":"observed"}')
        (self.directory / "resources.jsonl").write_text("stale success\n")
        with patch.object(resources, "version", return_value="synthetic"):
            resources.initialize(self.directory, self.directory)
        self.assertEqual((self.directory / "resources.jsonl").read_text(), "")
        self.assertEqual(resources.finalize(self.directory, 124), 1)
        report = json.loads(path.read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["harness_exit"], 124)
        path.write_text('{"status":"observed"}')
        resources.finalize(self.directory, 7)
        self.assertEqual(json.loads(path.read_text())["status"], "failed")

    def test_missing_report_and_bounded_retained_logs(self):
        log = self.directory / "build.log"
        log.write_bytes(b"x" * (resources.LOG_BYTES + 100))
        self.assertEqual(resources.finalize(self.directory, 0), 1)
        report = json.loads((self.directory / "resources-summary.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertLessEqual(log.stat().st_size, resources.LOG_BYTES)

    def test_handler_events_are_not_occupancy(self):
        (self.directory / "resources-summary.json").write_text('{"status":"observed"}')
        (self.directory / "server.log").write_text(
            "streaming-soak messages=160 would_block=20 resumes=19\n")
        self.assertEqual(resources.finalize(self.directory, 0), 0)
        report = json.loads((self.directory / "resources-summary.json").read_text())
        self.assertEqual(report["handler_events"], {
            "available": True, "messages": 160, "would_block": 20, "resumes": 19})

    def test_signal_reports_and_cleans_actual_synthetic_child(self):
        server = subprocess.Popen(["/bin/sleep", "20"])
        observer = None
        try:
            observer = subprocess.Popen([
                sys.executable, resources.__file__, "observe", "--directory", str(self.directory),
                "--server-pid", str(server.pid), "--duration", "10", "--seed", "47", "--",
                "/bin/sleep", "20"])
            samples = self.directory / "resources.jsonl"
            deadline = time.monotonic() + 3
            rows = []
            while time.monotonic() < deadline:
                if samples.exists():
                    rows = [json.loads(line) for line in samples.read_text().splitlines() if line.endswith("}")]
                if any(row["role"] == "client" for row in rows):
                    break
                time.sleep(.02)
            client = next(row for row in rows if row["role"] == "client")
            observer.terminate()
            self.assertEqual(observer.wait(timeout=3), 1)
            report = json.loads((self.directory / "resources-summary.json").read_text())
            self.assertIn("observer interrupted", report["errors"])
            self.assertFalse(Path(f"/proc/{client['pid']}").exists(), "synthetic child not reaped")
        finally:
            resources.stop(observer)
            resources.stop(server)

    def test_real_entrypoint_timeout_without_build(self):
        # Exercise GNU timeout + runner traps/report finalization, replacing ONLY
        # the inner workload. No compiler or gRPC peer runs in this fixture.
        source = Path(__file__).with_name("run_streaming_soak.sh").read_text()
        root = self.directory / "project"
        official = root / "tests" / "official"
        official.mkdir(parents=True)
        runner = official / "run_streaming_soak.sh"
        source = source.replace('    run_soak\n', '    sleep 20\n')
        source = source.replace('"${overall_timeout}s" bash', '"0.2s" bash')
        runner.write_text(source)
        observer = Path(resources.__file__).read_text()
        # Metadata tool versions are tested separately; no installed tool needed.
        observer = observer.replace('def version(command):', 'def version(command):\n    return "synthetic"\n\ndef unused_version(command):')
        (official / "streaming_soak_resources.py").write_text(observer)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("STREAMING_SOAK_")}
        result = subprocess.run(["bash", str(runner)], env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        report = json.loads((root / ".zig-cache/official/streaming-soak/resources-summary.json").read_text())
        self.assertEqual(report["harness_exit"], 124)
        self.assertEqual(report["status"], "failed")
        self.assertIn("harness_exit=124", result.stdout)


if __name__ == "__main__":
    unittest.main()
