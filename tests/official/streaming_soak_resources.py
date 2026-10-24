#!/usr/bin/env python3
"""Linux process evidence for bidi-slow-large-v1, not a heap/leak profiler."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import time

SCHEMA = 1
MAX_TICKS = 1800
LOG_BYTES = 1024 * 1024
METRICS = ("rss_kib", "fds", "threads")
UNAVAILABLE = {
    "admission_reservations": "grpc-go client; native server has no exported reservation snapshot",
    "queue_occupancy": "not exported by the existing peer; WouldBlock/resumes are events, not occupancy",
    "live_heap_bytes": "RSS includes allocator caches, stacks, code and libraries",
    "client_teardown": "client exits after RPC; no pre-exit idle observation hook",
    "server_post_deinit": "server remains alive during post-client idle; process exit is not zero-live-heap proof",
}
# Provisional screening budgets, NOT measured baselines or transport limits.
BUDGETS = {
    "server": {"rss_kib": 32768, "fds": 2, "threads": 0},
    "client": {"rss_kib": 65536, "fds": 2, "threads": 4},
}


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    temporary.replace(path)


def version(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=2, check=True)
        return (result.stdout or result.stderr).strip()[:256]
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def initialize(directory, root):
    # Replace stale success before configuration validation or any compilation.
    (directory / "resources.jsonl").write_text("")
    write_json(directory / "resources-summary.json", {
        "schema": SCHEMA, "status": "not_started", "unavailable": UNAVAILABLE,
    })
    write_json(directory / "resources-environment.json", {
        "schema": SCHEMA, "revision": version(["git", "-C", str(root), "rev-parse", "HEAD"]),
        "dirty": version(["git", "-C", str(root), "status", "--porcelain"]) != "",
        "kernel": platform.release(), "architecture": platform.machine(),
        "libc": platform.libc_ver(), "cpu_count": os.cpu_count(),
        "python": platform.python_version(), "zig": version(["zig", "version"]),
        "go": version(["go", "version"]),
        "build": "native ReleaseSafe; cleartext; default peer allocators; no sanitizer/gperftools",
        "workload": "bidi-slow-large-v1", "time_unix": time.time(),
        "cgroup_limits": {name: read_limit(name) for name in ("memory.max", "cpu.max", "pids.max")},
    })


def read_limit(name):
    try:
        return (Path("/sys/fs/cgroup") / name).read_text()[:128].strip()
    except OSError:
        return "unavailable (v2 root limit not readable; nested limits not inferred)"


def identity(pid, proc=Path("/proc")):
    # comm can contain spaces or ')'; starttime is field 22 after the last ')'.
    fields = (proc / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
    if fields[0] == "Z":
        raise ValueError("zombie")
    return fields[19]


def sample(pid, expected, proc=Path("/proc")):
    if identity(pid, proc) != expected:
        raise ValueError("PID identity changed")
    directory = proc / str(pid)
    fields = dict(line.split(":", 1) for line in (directory / "status").read_text().splitlines() if ":" in line)
    result = {"rss_kib": int(fields["VmRSS"].split()[0]), "threads": int(fields["Threads"]),
              "fds": sum(1 for _ in (directory / "fd").iterdir())}
    if identity(pid, proc) != expected:
        raise ValueError("PID identity changed during sample")
    return result


def compare(rows, duration):
    comparisons = []
    errors = []
    for role in ("server", "client"):
        phases = {}
        for phase in ("baseline", "warmup", "steady", "teardown"):
            selected = [row for row in rows if row["role"] == role and row["phase"] == phase and "rss_kib" in row]
            phases[phase] = {"count": len(selected), **{
                key: {"min": min(row[key] for row in selected), "max": max(row[key] for row in selected),
                      "median": statistics.median(row[key] for row in selected)}
                for key in METRICS if selected}}
        if not phases["warmup"]["count"]:
            errors.append(f"{role}: missing warmup samples")
        steady = [row for row in rows if row["role"] == role and row["phase"] == "steady" and "rss_kib" in row]
        checks = []
        width = len(steady) // 3
        if width < 3:
            errors.append(f"{role}: insufficient steady samples")
        else:
            for key in METRICS:
                early = statistics.median(row[key] for row in steady[:width])
                late = statistics.median(row[key] for row in steady[-width:])
                tolerance = max(BUDGETS[role][key], early * .25) if key == "rss_kib" else BUDGETS[role][key]
                checks.append({"metric": key, "comparison": "steady_last_third_minus_first_third",
                               "delta": late - early, "tolerance": tolerance, "ok": late - early <= tolerance})
            if role == "server":
                if not phases["baseline"]["count"] or phases["teardown"]["count"] < 3:
                    errors.append("server: missing baseline/teardown")
                else:
                    for key in METRICS:
                        reference = phases["steady"][key]["median"] if key == "rss_kib" else phases["baseline"][key]["median"]
                        tolerance = max(32768, reference * .25) if key == "rss_kib" else (1 if key == "fds" else 0)
                        delta = phases["teardown"][key]["median"] - reference
                        checks.append({"metric": key, "comparison": "post_client_idle_minus_steady_rss_or_pre_client_baseline",
                                       "delta": delta, "tolerance": tolerance, "ok": delta <= tolerance})
        warmup_to_steady = {
            key: phases["steady"][key]["median"] - phases["warmup"][key]["median"]
            for key in METRICS if phases["steady"]["count"] and phases["warmup"]["count"]
        }
        comparisons.append({"role": role, "phases": phases, "checks": checks,
                            "warmup_to_steady_delta_informational": warmup_to_steady})
    alerts = any(not check["ok"] for item in comparisons for check in item["checks"])
    return {"comparisons": comparisons, "comparison_errors": errors,
            "screen": "incomplete" if errors else "growth_alert" if alerts else "short_run" if duration < 60 else "within_provisional_tolerances"}


def stop(child):
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=1)


def observe(directory, server_pid, duration, seed, command):
    rows = []
    child = None
    errors = []
    child_status = None
    interval = max(.2, (duration + 35) / MAX_TICKS)
    start = time.monotonic()
    warmup = min(5, duration / 5)
    identities = {}
    interrupted = False

    def interrupt(signum, _frame):
        nonlocal interrupted
        interrupted = True

    def pause(delay):
        until = time.monotonic() + delay
        while not interrupted and time.monotonic() < until:
            time.sleep(max(0, min(.2, until - time.monotonic())))

    previous = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        with (directory / "resources.jsonl").open("w") as output:
            def record(role, pid, phase):
                row = {"role": role, "pid": pid, "phase": phase, "elapsed_seconds": round(time.monotonic() - start, 6)}
                try:
                    if role not in identities:
                        identities[role] = identity(pid)
                    row["start_ticks"] = identities[role]
                    row.update(sample(pid, identities[role]))
                except (OSError, ValueError, KeyError, IndexError):
                    row["unavailable"] = "missing, unreadable, exited or changed process data"
                    errors.append(f"{role}: {row['unavailable']}")
                rows.append(row)
                output.write(json.dumps(row, sort_keys=True) + "\n")
                output.flush()

            record("server", server_pid, "baseline")
            if errors:
                raise RuntimeError("server baseline unavailable")
            # stdout is the existing client log. No payload, environment or argv dump.
            child = subprocess.Popen(command)
            # Baseline collection and process creation are not traffic warmup.
            traffic_start = time.monotonic()
            deadline = traffic_start + duration + 30
            ticks = 0
            while child.poll() is None:
                if interrupted:
                    raise RuntimeError("observer interrupted")
                if time.monotonic() >= deadline:
                    raise RuntimeError("client observation timeout")
                if ticks >= MAX_TICKS:
                    raise RuntimeError("sample budget exhausted")
                phase = "warmup" if time.monotonic() - traffic_start < warmup else "steady"
                record("server", server_pid, phase)
                record("client", child.pid, phase)
                # A client exiting during /proc reads is not a zero measurement.
                if errors:
                    if "unavailable" in rows[-1] and "unavailable" not in rows[-2] and child.poll() is not None:
                        errors.pop()
                        break
                    raise RuntimeError("process measurement unavailable")
                ticks += 1
                pause(interval)
            child_status = child.wait()
            if child_status != 0:
                raise RuntimeError("client failed")
            # Fixed two-second post-client idle window, not Server.deinit.
            for _ in range(10):
                if interrupted:
                    raise RuntimeError("observer interrupted")
                record("server", server_pid, "teardown")
                pause(.2)
            if interrupted:
                raise RuntimeError("observer interrupted")
    except (OSError, RuntimeError) as exc:
        errors.append(str(exc))
    finally:
        try:
            stop(child)
        except (OSError, subprocess.TimeoutExpired):
            errors.append("child cleanup failed; outer process-group timeout remains authoritative")
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    result = compare(rows, duration)
    failed = bool(errors or result["screen"] in ("incomplete", "growth_alert"))
    write_json(directory / "resources-summary.json", {
        "schema": SCHEMA, "status": "failed" if failed else "observed", "errors": errors,
        "client_exit": child_status, "duration_seconds": duration, "seed": seed,
        "sample_interval_seconds": interval, "warmup_seconds": warmup,
        "samples": len(rows), "unavailable": UNAVAILABLE, **result,
    })
    return int(failed)


def finalize(directory, harness_exit):
    path = directory / "resources-summary.json"
    try:
        result = json.loads(path.read_text())
    except (OSError, ValueError):
        result = {"schema": SCHEMA, "status": "missing_report", "unavailable": UNAVAILABLE}
    complete = result.get("status") == "observed"
    try:
        result["handler_events"] = {"available": False, "reason": "no terminal peer counters"}
        server_log = directory / "server.log"
        if server_log.exists():
            with server_log.open("rb") as source:
                source.seek(max(0, server_log.stat().st_size - LOG_BYTES))
                tail = source.read(LOG_BYTES).decode("utf-8", errors="replace")
            matches = re.findall(r"^streaming-soak messages=(\d{1,12}) would_block=(\d{1,12}) resumes=(\d{1,12})$", tail, re.MULTILINE)
            if matches:
                result["handler_events"] = {"available": True, **dict(zip(
                    ("messages", "would_block", "resumes"), map(int, matches[-1])))}
        # Bound retained log artifacts, preserving diagnostic tails. Never include binaries.
        for name in ("harness", "build", "server", "client"):
            log = directory / (name + ".log")
            if log.exists() and log.stat().st_size > LOG_BYTES:
                with log.open("rb") as source:
                    source.seek(-LOG_BYTES + 256, os.SEEK_END)
                    tail = source.read()
                log.write_bytes(b"[earlier output truncated to bound retained artifact]\n" + tail)
    except OSError:
        complete = False
        result.setdefault("errors", []).append("log finalization failed")
    # Publish success atomically only after every log operation has completed.
    result["harness_exit"] = harness_exit if harness_exit or complete else 1
    result["status"] = "passed" if complete and harness_exit == 0 else "failed"
    write_json(path, result)
    return 0 if result["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "observe", "finalize"))
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--server-pid", type=int)
    parser.add_argument("--duration", type=int)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--harness-exit", type=int, default=1)
    argv = sys.argv[1:]
    separator = argv.index("--") if "--" in argv else len(argv)
    command = argv[separator + 1:]
    args = parser.parse_args(argv[:separator])
    if args.action == "init":
        initialize(args.directory, args.root)
        return 0
    if args.action == "finalize":
        return finalize(args.directory, args.harness_exit)
    if not args.server_pid or not args.duration or not 1 <= args.duration <= 99999 or not command:
        parser.error("observe requires server PID, bounded duration and command")
    return observe(args.directory, args.server_pid, args.duration, args.seed,
                   command)


if __name__ == "__main__":
    sys.exit(main())
