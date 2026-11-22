# Large unary RPC: split receive and send (2026-11-21)

**Optimize the large response first.** With plaintext, grpc-lite trails Tonic
by 17% for a large request, 57% for a large response, and 44% when both are
large. The symmetric rerun (1,242 vs 2,210 RPC/s) reproduces the direction and
scale of the historical 1,289 vs 2,191 result. The largest excess server CPU
cost appears when the response is large, even when the request is only 64 B.

## Results

Values in each pair are **grpc-lite / Tonic**. `L` = 1 MiB, `S` = 64 B.
36 unprofiled runs completed 343,198 validated RPCs, zero errors.

| Transport | Request → response | RPC/s | P99 (ms) | Server CPU (%) | Server CPU (µs/RPC) |
| --- | --- | ---: | ---: | ---: | ---: |
| Plain | L → S | 3,078 / 3,705 | 11.55 / 13.60 | 73.2 / 92.2 | 237 / 248 |
| Plain | S → L | 2,139 / 4,954 | 16.13 / 13.08 | 83.8 / 83.5 | 392 / 169 |
| Plain | L → L | 1,242 / 2,210 | 28.59 / 21.56 | 79.7 / 84.3 | 642 / 386 |
| TLS | L → S | 2,062 / 3,021 | 21.32 / 13.12 | 81.9 / 94.0 | 397 / 312 |
| TLS | S → L | 1,549 / 2,326 | 23.48 / 20.61 | 83.8 / 82.7 | 537 / 351 |
| TLS | L → L | 867 / 1,344 | 47.11 / 28.32 | 84.9 / 86.5 | 982 / 624 |

## Attribution

- **Large response, plaintext:** 204/621 on-CPU samples (32.9%) hit Zig
  `memcpyFast`. The callers account for all 204: 70 in nested protobuf encoding,
  45 duplicating the encoded payload in `UnaryResponse.ok`, 54 appending to the
  cleartext write batch, 18 growing that batch, and 17 copying to nghttp2 in
  `readResponseData`. Thus 18.5% of all samples are response-construction copies
  and 14.3% are transport copies. Zero fill (`fastMemset`) contributes another
  5.3%. Kernel socket copy (`_copy_from_iter`) takes 12.9%. Tonic spends 10.9%
  in libc memmove and 27.6% in kernel page clearing, but uses less than half as
  much total server CPU per RPC. Percentages are within-server, not speedups.
- **Large request, plaintext:** of 550 grpc-lite samples, 69 are copies inside
  protobuf decode and 61 inside `frame.appendUnaryData`; kernel `_copy_to_iter`
  adds 15.1%. Tonic also spends CPU in memmove (22.7%) and `_copy_to_iter`
  (21.3%). grpc-lite's lower throughput here does **not** correspond to higher
  server CPU per RPC. An independent C++ HTTP/2 trace found 52.6 vs 3.3 incoming
  WINDOW_UPDATE frames and 25.8 vs 1.3 client send-stall-list additions per
  completed call. Credit turnover is a plausible request-side contributor; the
  trace counts events, not wait duration or lost throughput.
- **Framing versus credit:** for a 1 MiB response the same C++ client observed
  exactly 65 DATA frames per grpc-lite reply (64 × 16,384 B + 13 B), versus
  one per Tonic reply (1,048,589 B). This is segmentation, not evidence of time
  blocked on a window. Client send-stall counts measure **request** credit only.
  These traces include connection setup; tracing was never enabled for timing.
- **Both large:** grpc-lite's plaintext memcpy leaf rises to 34.8% (203/584);
  62 samples are inbound assembly/decode copies, 140 are the response copy
  sites above, and one is unresolved at `onRead`. With TLS, grpc-lite still
  spends 21.7% in Zig memcpy and 8.9% in libc memmove; OpenSSL AES-GCM also
  appears. Tonic spends 22.7% in ring AES-GCM encrypt/decrypt combined.
  Encryption adds cost, but cannot explain the plaintext gap.

**First A/B:** pass the encoded writer buffer into an owning unary response
without duplicating it; keep the wire bytes, handler semantics, and HTTP/2
settings fixed. Re-run S → L as the target and L → S as the control. Next test
cleartext write-batch copies separately. Defer receive-window tuning to a
request-side A/B. No transport or handler change is part of this baseline.

`plain.jsonl` and `tls.jsonl` hold every timed run. `hotspots.tsv` contains the
top ten flat server CPU symbols per cell (all 12 profiles, zero lost samples).
`copy-sites.tsv` attributes plaintext Zig memcpy samples by following saved
x86-64 frame pointers and resolving return PCs minus one, including inline
frames (`addr2line -afip -e SERVER PC ...`). `flow.jsonl` contains short
independent plaintext C++ traces summarized as raw counts. Machine-local raw
profiles and trace logs: `/tmp/opencode/asym-1m-JGxSQKR2/`.

## Measurement contract

`grpc.testing.TestService/UnaryCall`, localhost IPv4, identity message compression.
The same C++ gRPC 1.84.3 client binary drives both servers in both transport modes.
One closed-loop process, 32 synchronous workers, one persistent channel and local
subchannel pool per worker, no retries. Each call checks gRPC status and response
body length. Sizes below are protobuf **body** bytes, excluding envelopes.
The client reuses its request; both server handlers construct the requested
zero-filled response per RPC. These are end-to-end measurements of these handlers
and transports, not raw socket throughput.

- AMD Ryzen 9 9955HX, Fedora 45, Linux 7.3.3, CPU governor `performance`.
  Client on CPUs 0–7, server on CPU 15, distinct physical cores. Default HTTP/2 settings.
- grpc-lite `af1914862dd9552bf25fb03e7544c213a23202a7`, frozen ReleaseFast
  interop server with the historical benchmark reactor CLI patch. One reactor;
  the patch does not change the unary handler. TLS backend: system OpenSSL 4.0.3.
- Tonic 0.14.6 (`prost` bytes fields; rustls/ring), one Tokio worker and the
  whole process pinned to the same single CPU as grpc-lite in its respective turn.
- Each measured cell: three fresh server/client pairs, rotated shape and server
  order, 1 s warmup after all workers connect, 4 s load plus drain. Plaintext
  matrix first, then TLS with the same CA, server identity and IP SAN verification.
  Rows report medians of per-run metrics; P99 is not pooled across rounds.
- Server CPU sums process user and system ticks over an interior 3.7 s load
  window. 100% means one core. CPU µs/RPC is estimated per run as
  `cpu_pct * 10000 / ops_per_second`, then aggregated. It excludes CPU charged
  elsewhere and does not measure time blocked.
- Profiles are *separate* repeats, `perf record -p SERVER_PID -e cpu-clock -F 199
  --call-graph dwarf,8192`, including kernel CPU in the server context.
  No profiled throughput or latency enters the results.

## Follow-up: owned writer buffer A/B

The official unary interop handler now returns `writer.toOwnedSlice()` instead
of passing the encoded bytes through the copying `UnaryResponse.ok` constructor.
Both servers were rebuilt from `af19148` without the historical CLI patch,
using `zig build streaming-soak-peer -Doptimize=ReleaseFast -Dtls-backend=openssl`.
Only the handler return differs. The client binary, placement, plaintext
transport, windows, payloads and timing are as above. Four rounds per shape,
alternating A/B order; 169,638 successful calls, no failures.

| Request → response | RPC/s (A → B) | P99 ms (A → B) | Server CPU % (A → B) | CPU µs/RPC (A → B) |
| --- | ---: | ---: | ---: | ---: |
| 64 B → 1 MiB | 2,139 → 2,264 (+5.9%) | 16.17 → 15.33 | 83.5 → 82.7 | 390 → 365 (−6.5%) |
| 1 MiB → 64 B | 3,057 → 3,093 (+1.2%) | 11.65 → 11.39 | 73.6 → 73.4 | 241 → 237 |

Separate 199 Hz frame-pointer profiles of the large response show 40/658
server samples copying the encoded payload in `UnaryResponse.init` before,
0/657 after; no memcpy samples moved to `toOwnedSlice` in this build.
Protobuf writer copies (94 samples after) and `CleartextWriteBatch.append`,
including growth (72), remain. This is a handler improvement, not a general
transport speedup. The control's throughput ranges overlap.

`owned-response/ab.jsonl` contains all timed observations. To repeat, pass
`BENCH BASELINE_SERVER CLIENT OUT ab OWNED_SERVER` to `run.py`, then repeat
with `profile-ab`. A/B binary hashes (SHA-256), respectively:
`9768307ba148e2785ad6c859d68ee6115e78755b9b7579b0fecaa75ff35150d2`,
`0ab71afaff38b791ed7c9e1828b8e98d990f69280d19c6252c29e2d526e351f4`.
Local profiles and symbolized callers: `/tmp/opencode/owned-unary-C5obSvB3/`.
Seven grpc-go interop checks passed on B, including large unary, gzip response
and status propagation.

## Follow-up: cleartext socket-write batching

Keep the owned-response handler as A. For B, increase only the server's
cleartext socket-write batch target from 64 to 256 KiB. nghttp2 frame sizes,
flow-control windows, write watermarks and TLS are unchanged. No capacity is
preallocated and partial batches are submitted at the end of each flush.

Same C++ binary and placement as above. Two campaigns, four alternating A/B
pairs per shape in each. Medians over all eight unprofiled runs per cell:

| Request → response | RPC/s (64 → 256 KiB batch) | P99 ms | Server CPU % | CPU µs/RPC |
| --- | ---: | ---: | ---: | ---: |
| 64 B → 1 MiB | 2,262 → 2,554 (+12.9%) | 15.36 → 13.90 | 82.7 → 86.5 | 366 → 338 |
| 1 MiB → 64 B | 3,064 → 3,078 (+0.5%) | 11.71 → 11.44 | 73.5 → 73.6 | 240 → 239 |
| 1 MiB → 1 MiB | 1,259 → 1,424 (+13.2%) | 27.23 → 24.44 | 79.7 → 80.5 | 634 → 566 |
| 1 KiB → 1 KiB | 136,271 → 136,528 (+0.2%) | 0.301 → 0.301 | 63.2 → 63.2 | 4.63 → 4.65 |

Large-response gain varied between the two campaigns; the first had only a
4.0% throughput gain and slightly higher CPU/RPC. Do not use the pooled number
as a guaranteed speedup. Separate large-response CPU profiles put Zig memcpy
at 28.6% (A) and 22.7% (B); kernel page clearing rose from 16.9% to 26.2%.
The larger target allows larger transient contiguous allocations; these runs
did not measure memory peaks with many active connections.

Four earlier alternatives were discarded. Each used its own contemporaneous
baseline with the same owned-response handler, four alternating pairs per shape:

| Trial | 64 B → 1 MiB RPC/s (A → B) | Observation |
| --- | ---: | --- |
| Reserve capacity for frame-sized chunks | 2,299 → 2,236 | Growth-copy hotspot disappeared without an end-to-end gain. |
| Negotiate larger unary DATA frames up to the 64 KiB write target | 2,301 → 1,990 | Trace confirmed 17 DATA frames per response instead of 65. |
| Append large unary DATA directly to the batch via nghttp2's send-data callback when room permits | 2,325 → 2,235 | Skipping an intermediate copy did not pay off. |
| Submit each ≥16 KiB chunk as a separate socket write | 2,260 → 1,453 | More, smaller writes performed worst. |

`cleartext-batching/rounds.jsonl` contains all 192 timed observations (27,453,494
validated calls, zero errors); `cleartext-batching/hotspots.tsv` contains the
flat server CPU profiles for the retained change and both asymmetric shapes.
Use `run.py BENCH BASELINE_SERVER CLIENT OUT ab CANDIDATE_SERVER larger` twice
in separate output directories; use `profile-ab` for separate CPU sampling.
Machine-local trial binaries, rejected patches, perf and trace logs:
`/tmp/opencode/clear-batch-FftwviBm/`. ReleaseSafe/OpenSSL: 342 tests passed;
the official HTTP/2 framing and TLS profile suites passed.

## Reproduce

For the later server receive-path experiment based on PR #115, see
`receive/README.md`.

Benchmark source: https://github.com/fanyang89/rpc-framework-bench
at `dd1f8f65a7fcc437931f6b1adddc1ba63703b45a`. Use its built `bin/tonic-server`
and `scripts/certificates.sh` for a valid benchmark CA and localhost certificate.
Apply the included client patch to a disposable copy of this source. The only
changes are credential selection and a marker before warmup for CPU sampling.
Use a gRPC C++ 1.84.3 CMake installation.

```sh
# BENCH, GRPC_PREFIX, LITE, OUT and EVIDENCE are absolute paths.
git -C "$BENCH" apply "$EVIDENCE/client.patch"
cmake -S "$BENCH/native" -B "$OUT/build" -G Ninja -DGRPC_ONLY=ON \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$GRPC_PREFIX"
cmake --build "$OUT/build"
for phase in plain tls profile-plain profile-tls flow; do
  python3 "$EVIDENCE/run.py" "$BENCH" "$LITE" "$OUT/build/grpc-native" \
    "$OUT" "$phase" > "$OUT/$phase.jsonl" || exit 1
done
```

SHA-256 of tested binaries:

| Binary | SHA-256 |
| --- | --- |
| C++ client | `e4c4345711073e0ba26bbffb833ca1d567ec522c6d6169b0f6872424e5970ab8` |
| grpc-lite | `5b3b5fde4a591df9c519bf1279fe7d70a8956baa821d4fb568390825817fc1c3` |
| Tonic | `ce00b9d6a00586117c669ed1596507d90e845aa2fa07054502d13155202b51c7` |
