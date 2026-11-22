"""Reproduce the large-unary matrix with the TLS-enabled rpc-framework-bench client."""

import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess as sp
import sys
import time

bench, lite, client, out = map(Path, sys.argv[1:5])
phase = sys.argv[5]
assert phase in (
    "plain",
    "tls",
    "profile-plain",
    "profile-tls",
    "flow",
    "ab",
    "tls-ab",
    "profile-ab",
)
flow = phase == "flow"
profile = phase.startswith("profile-")
tls = phase.endswith("tls") or phase == "tls-ab"
out.mkdir(parents=True, exist_ok=True)
certs = bench / "bin/certs"
workers = os.environ.get("BENCH_WORKERS", "32")


def ticks(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return sum(map(int, fields[11:13]))


def run(server, req, resp, rep, binary=lite):
    name = f"{phase}-{server}-{req}-{resp}-{rep}"
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    addr = f"127.0.0.1:{port}"
    env = dict(os.environ, SERVER_THREADS="1", SERVER_ADDR=addr)
    for key in ("TLS_CERT", "TLS_KEY", "TLS_CA"):
        env.pop(key, None)
    args = [binary, f"--port={port}", f"--use_tls={str(tls).lower()}"]
    if tls:
        env.update(
            TLS_CERT=str(certs / "server.pem"),
            TLS_KEY=str(certs / "server.key"),
            TLS_CA=str(certs / "ca.pem"),
        )
        args += [
            "--tls_cert_file=" + env["TLS_CERT"],
            "--tls_key_file=" + env["TLS_KEY"],
        ]
    if server == "tonic":
        args = [bench / "bin/tonic-server"]
    with (out / f"{name}.log").open("w") as log:
        srv = sp.Popen(["taskset", "-c", "15", *args], stdout=log, stderr=log, env=env)
        cli = perf = None
        try:
            for _ in range(150):
                if srv.poll() is not None:
                    raise RuntimeError(f"server exited: {name}")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.02)
            else:
                raise TimeoutError(addr)
            if flow:
                # No warmup: the trace and the completed-call count cover the same RPCs.
                path = out / f"{name}.trace"
                with path.open("w") as trace:
                    stdout = sp.check_output(
                        [
                            "taskset",
                            "-c",
                            "0-7",
                            client,
                            "client",
                            addr,
                            workers,
                            str(req),
                            str(resp),
                            "0",
                            "100",
                        ],
                        stderr=trace,
                        env=dict(env, GRPC_TRACE="http,http2_stream_state"),
                        text=True,
                        timeout=25,
                    )
                result = json.loads(stdout)
                assert result["errors"] == 0 and result["completed"] > 0
                events = path.read_text()
                print(
                    json.dumps(
                        dict(
                            server=server,
                            req=req,
                            resp=resp,
                            completed=result["completed"],
                            transport_stalls=events.count(
                                "add to stalled_by_transport"
                            ),
                            stream_stalls=events.count("add to stalled_by_stream"),
                            response_data_frames=events.count("]: DATA len:"),
                            window_updates=sum(
                                "INCOMING[" in line and "WINDOW_UPDATE" in line
                                for line in events.splitlines()
                            ),
                        )
                    ),
                    flush=True,
                )
                return
            cli = sp.Popen(
                [
                    "taskset",
                    "-c",
                    "0-7",
                    client,
                    "client",
                    addr,
                    workers,
                    str(req),
                    str(resp),
                    "1000",
                    "4000",
                ],
                stdout=sp.PIPE,
                stderr=sp.PIPE,
                text=True,
                env=env,
            )
            deadline = time.monotonic() + 15
            while select.select(
                [cli.stderr], [], [], max(0, deadline - time.monotonic())
            )[0]:
                line = cli.stderr.readline()
                if line == "workers ready\n":
                    break
                if not line:
                    raise RuntimeError(f"no ready marker: {name}")
                log.write(line)
            else:
                raise TimeoutError(name)
            time.sleep(1.05)
            if profile:
                perf = sp.Popen(
                    [
                        "perf",
                        "record",
                        "-e",
                        "cpu-clock",
                        "-F",
                        "199",
                        "--call-graph",
                        "fp" if phase == "profile-ab" else "dwarf,8192",
                        "-m",
                        "32",
                        "-o",
                        out / f"{name}.perf",
                        "-p",
                        str(srv.pid),
                    ],
                    stderr=log,
                )
            before = ticks(srv.pid)
            start = time.monotonic()
            time.sleep(3.7)
            cpu_s = (ticks(srv.pid) - before) / os.sysconf("SC_CLK_TCK")
            wall_s = time.monotonic() - start
            if perf:
                perf.send_signal(signal.SIGINT)
                if perf.wait(timeout=10) not in (
                    0,
                    -signal.SIGINT,
                    128 + signal.SIGINT,
                ):
                    raise RuntimeError(f"perf failed: {name}")
            stdout, stderr = cli.communicate(timeout=20)
            log.write(stderr)
            result = json.loads(stdout)
            assert cli.returncode == result["errors"] == 0 and result["completed"] > 0
            result.update(
                phase=phase,
                server=server,
                req=req,
                resp=resp,
                rep=rep,
                workers=int(workers),
                cpu_s=cpu_s,
                cpu_window_s=wall_s,
                cpu_pct=100 * cpu_s / wall_s,
                server_peak_rss_kib=int(
                    next(
                        line.split()[1]
                        for line in Path(f"/proc/{srv.pid}/status")
                        .read_text()
                        .splitlines()
                        if line.startswith("VmHWM:")
                    )
                ),
            )
            print(json.dumps(result), flush=True)
        finally:
            for process in (perf, cli, srv):
                if process and process.poll() is None:
                    process.kill()
                    process.wait()


large = 1048576
if phase.endswith("ab"):
    candidate = sys.argv[7] if len(sys.argv) > 7 else "owned"
    cases = [(64, large), (large, 64)]
    if candidate != "owned" and not profile:
        cases.extend([(large, large), (1024, 1024)])
    for rep in range(1 if profile else 4):
        for i, (req, resp) in enumerate(cases):
            variants = [("baseline", lite), (candidate, Path(sys.argv[6]))]
            for label, binary in variants[:: 1 if (rep + i) % 2 == 0 else -1]:
                run(label, req, resp, rep + 1, binary)
    sys.exit(0)

for rep in range(1 if profile or flow else 3):
    cases = [(large, 64), (64, large), (large, large)]
    for i, (req, resp) in enumerate(cases[rep:] + cases[:rep]):
        names = ["grpc-lite", "tonic"]
        for server in names[:: 1 if (rep + i) % 2 == 0 else -1]:
            run(server, req, resp, rep + 1)
