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

    def __init__(self, clock, end=10, status=0, first_poll_delay=0):
        self.clock, self.end, self.status = clock, end, status
        self.terminated = False
        self.first_poll_delay = first_poll_delay

    def poll(self):
        self.clock.sleep(self.first_poll_delay)
        self.first_poll_delay = 0
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

    def observe(self, end=10, status=0, missing=False, baseline_delay=0, launch_delay=0, first_poll_delay=0):
        clock = Clock()
        child = Child(clock, end, status, first_poll_delay)
        metrics = {"rss_kib": 1024, "fds": 5, "threads": 2}
        samples = 0

        def sample(*_args):
            nonlocal samples
            if samples == 0:
                clock.sleep(baseline_delay)
            samples += 1
            if missing:
                raise FileNotFoundError()
            return metrics

        def launch(_command):
            clock.sleep(launch_delay)
            child.end = clock.now + end
            return child

        with patch.object(resources.time, "monotonic", clock.monotonic), \
                patch.object(resources.time, "sleep", clock.sleep), \
                patch.object(resources.subprocess, "Popen", side_effect=launch), \
                patch.object(resources, "identity", return_value="42"), \
                patch.object(resources, "sample", side_effect=sample):
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

    def test_traffic_clock_starts_after_baseline_and_client_launch(self):
        status, report, _ = self.observe(baseline_delay=50, launch_delay=50)
        self.assertEqual(status, 0)
        self.assertEqual(report["screen"], "short_run")
        for peer in report["comparisons"]:
            self.assertGreater(peer["phases"]["warmup"]["count"], 0)
            self.assertGreaterEqual(peer["phases"]["steady"]["count"], 9)
        self.assertEqual(report["client_exit"], 0)

    def test_missing_warmup_observation_is_incomplete_and_nonzero(self):
        status, report, _ = self.observe(first_poll_delay=3)
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["screen"], "incomplete")
        self.assertEqual(report["comparison_errors"], [
            "server: missing warmup samples", "client: missing warmup samples"])

    def test_each_peer_requires_valid_warmup_samples(self):
        self.observe()
        rows = [json.loads(line) for line in (self.directory / "resources.jsonl").read_text().splitlines()]
        for role in ("server", "client"):
            for unavailable in (False, True):
                with self.subTest(role=role, unavailable=unavailable):
                    without_warmup = [row for row in rows if not (row["role"] == role and row["phase"] == "warmup")]
                    if unavailable:
                        without_warmup.append({"role": role, "phase": "warmup", "unavailable": "injected missing data"})
                    report = resources.compare(without_warmup, 600)
                    self.assertEqual(report["screen"], "incomplete")
                    self.assertEqual(report["comparison_errors"], [f"{role}: missing warmup samples"])

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
                rows.append({"role": role, "phase": "baseline" if index == 0 else "warmup" if index == 1 else "teardown" if index >= 27 else "steady",
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

    def test_truncation_failure_never_publishes_passed(self):
        summary = self.directory / "resources-summary.json"
        summary.write_text('{"status":"observed"}')
        log = self.directory / "build.log"
        original = b"x" * (resources.LOG_BYTES + 100)
        log.write_bytes(original)

        def fail_truncation(path, _data):
            self.assertEqual(path, log)
            self.assertEqual(json.loads(summary.read_text())["status"], "observed")
            raise OSError("injected truncation failure")

        with patch.object(Path, "write_bytes", fail_truncation):
            self.assertEqual(resources.finalize(self.directory, 0), 1)
        report = json.loads(summary.read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["harness_exit"], 1)
        self.assertIn("log finalization failed", report["errors"])
        self.assertEqual(log.read_bytes(), original)
        self.assertFalse(summary.with_suffix(".tmp").exists())

    def test_shell_status_matches_injected_log_finalization_failure(self):
        # Keep real outer dispatch/finalization; replace only the heavy workload
        # and inject the exact write failure into the copied observer.
        root = self.directory / "project"
        official = root / "tests" / "official"
        official.mkdir(parents=True)
        runner = official / "run_streaming_soak.sh"
        source = Path(__file__).with_name("run_streaming_soak.sh").read_text()
        source = source.replace('    run_soak\n', """    printf '{"status":"observed"}\\n' >"$work_dir/resources-summary.json"
    head -c 1048676 /dev/zero >"$work_dir/build.log"
""")
        runner.write_text(source)
        observer = Path(resources.__file__).read_text()
        observer = observer.replace('def version(command):', 'def version(command):\n    return "synthetic"\n\ndef unused_version(command):')
        observer = observer.replace('if __name__ == "__main__":', '''def fail_truncation(path, data):
    if path.name == "build.log":
        raise OSError("injected truncation failure")
    return original_write_bytes(path, data)

original_write_bytes = Path.write_bytes
Path.write_bytes = fail_truncation

if __name__ == "__main__":''')
        (official / "streaming_soak_resources.py").write_text(observer)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("STREAMING_SOAK_")}
        result = subprocess.run(["bash", str(runner)], env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads((root / ".zig-cache/official/streaming-soak/resources-summary.json").read_text())
        self.assertEqual(report["harness_exit"], result.returncode)
        self.assertEqual(report["status"], "failed")
        self.assertIn("log finalization failed", report["errors"])
        self.assertIn("harness_exit=1", result.stdout)

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
