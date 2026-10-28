#!/usr/bin/env python3
"""Reproduce this fixed evidence aggregate; never launch peers or import the observer.

Print deterministic JSON; --duckdb also cross-checks every nonempty window with SQL.
Run without Python -O: assertions validate the preserved summaries and provenance.
"""
import gzip
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
METRICS = ("rss_kib", "fds", "threads")
PHASES = ("baseline", "warmup", "steady", "teardown")


def describe(rows):
    if not rows:
        return {"count": 0}
    return {"count": len(rows), **{
        metric: {"min": min(r[metric] for r in rows),
                 "median": statistics.median(r[metric] for r in rows),
                 "max": max(r[metric] for r in rows)} for metric in METRICS}}


def main():
    for line in (ROOT / "upstream.sha256").read_text().splitlines():
        digest, name = line.split("  ")
        path = ROOT / name
        raw = gzip.decompress(Path(str(path) + ".gz").read_bytes()) if name.endswith(".jsonl") else path.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == digest, name
    metadata = json.loads((ROOT / "metadata.json").read_text())
    result = {"schema": 1, "units": {"rss_kib": "KiB (1024 bytes)",
              "fds": "count", "threads": "count", "elapsed_seconds": "observer monotonic seconds"},
              "trials": [], "across_trials": {}}
    sql_expected = []
    environments = []
    for trial in range(1, 4):
        directory = ROOT / f"trial-{trial}"
        rows = [json.loads(line) for line in gzip.decompress((directory / "resources.jsonl.gz").read_bytes()).splitlines()]
        assert len(rows) == 3407 and all(set(r) == {"elapsed_seconds", "fds", "phase", "pid", "role", "rss_kib", "start_ticks", "threads"} for r in rows)
        summary = json.loads((directory / "resources-summary.json").read_text())
        assert summary["samples"] == len(rows) and summary["status"] == "passed"
        assert summary["client_exit"] == summary["harness_exit"] == int((directory / "invocation.exit").read_text()) == 0
        assert summary["errors"] == summary["comparison_errors"] == []
        assert (summary["duration_seconds"], summary["seed"], summary["warmup_seconds"]) == (600, 47, 5)
        assert summary["sample_interval_seconds"] == 635 / 1800
        env = json.loads((directory / "resources-environment.json").read_text())
        env.pop("time_unix")
        environments.append(env)
        entry = {"trial": trial, "samples": len(rows), "roles": {}}
        for role in ("server", "client"):
            selected = [r for r in rows if r["role"] == role]
            assert len({(r["pid"], r["start_ticks"]) for r in selected}) == 1
            assert selected == sorted(selected, key=lambda r: r["elapsed_seconds"])
            windows = {p: [r for r in selected if r["phase"] == p] for p in PHASES}
            width = len(windows["steady"]) // 3
            assert width == 561
            windows["steady_first_third"] = windows["steady"][:width]
            windows["steady_last_third"] = windows["steady"][-width:]
            stats = {p: describe(rs) for p, rs in windows.items()}
            recorded = next(c for c in summary["comparisons"] if c["role"] == role)
            assert {p: stats[p] for p in PHASES} == recorded["phases"]
            deltas = {}
            for metric in METRICS:
                med = lambda phase: stats[phase][metric]["median"]
                early, late = med("steady_first_third"), med("steady_last_third")
                delta = late - early
                budget = {"server": (32768, 2, 0), "client": (65536, 2, 4)}[role][METRICS.index(metric)]
                tolerance = max(budget, early * .25) if metric == "rss_kib" else budget
                expected = {"metric": metric, "comparison": "steady_last_third_minus_first_third",
                            "delta": delta, "tolerance": tolerance, "ok": delta <= tolerance}
                assert expected in recorded["checks"] and expected["ok"]
                warmup_delta = med("steady") - med("warmup")
                assert warmup_delta == recorded["warmup_to_steady_delta_informational"][metric]
                deltas[metric] = {"late_minus_early": delta, "warmup_to_steady": warmup_delta}
                if role == "server":
                    reference = med("steady") if metric == "rss_kib" else med("baseline")
                    idle_delta = med("teardown") - reference
                    idle_tolerance = max(32768, reference * .25) if metric == "rss_kib" else (1 if metric == "fds" else 0)
                    expected = {"metric": metric, "comparison": "post_client_idle_minus_steady_rss_or_pre_client_baseline",
                                "delta": idle_delta, "tolerance": idle_tolerance, "ok": idle_delta <= idle_tolerance}
                    assert expected in recorded["checks"] and expected["ok"]
                    deltas[metric].update(idle_screen_delta=idle_delta,
                                         idle_minus_baseline=med("teardown") - med("baseline"))
            for phase, rs in windows.items():
                if not rs:
                    continue
                sql_expected.append({"trial": trial, "role": role, "phase": phase, "count": len(rs),
                    "elapsed_min": min(r["elapsed_seconds"] for r in rs),
                    "elapsed_max": max(r["elapsed_seconds"] for r in rs),
                    **{f"{m}_{s}": stats[phase][m][s] for m in METRICS for s in ("min", "median", "max")}})
            entry["roles"][role] = {"windows": stats, "deltas": deltas}
        assert summary["screen"] == "within_provisional_tolerances"
        entry["handler_events"] = summary["handler_events"]
        entry["client_result"] = metadata["trials"][trial - 1]["client_result"]
        result["trials"].append(entry)
    assert environments[0] == environments[1] == environments[2]
    assert environments[0]["revision"] == metadata["revision"] and not environments[0]["dirty"]
    # Equal weight per trial; never pool the correlated time-series samples.
    for role in ("server", "client"):
        result["across_trials"][role] = {}
        for metric in METRICS:
            values = [t["roles"][role]["windows"]["steady"][metric]["median"] for t in result["trials"]]
            deltas = [t["roles"][role]["deltas"][metric]["late_minus_early"] for t in result["trials"]]
            result["across_trials"][role][metric] = {
                "steady_trial_medians": {"min": min(values), "median": statistics.median(values), "max": max(values)},
                "late_minus_early_trial_deltas": {"min": min(deltas), "median": statistics.median(deltas), "max": max(deltas)}}
    if "--duckdb" in sys.argv[1:]:
        query = (ROOT / "recompute.sql").read_text()
        output = subprocess.check_output(["duckdb", "-json", ":memory:"], input=query, cwd=ROOT, text=True)
        key = lambda r: (r["trial"], r["role"], r["phase"])
        assert sorted(json.loads(output), key=key) == sorted(sql_expected, key=key)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
