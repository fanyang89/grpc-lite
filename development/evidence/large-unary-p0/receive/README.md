# Cleartext socket receive size (2026-11-22)

A = PR #115 (`6786d40`). B uses the otherwise idle inline 16 KiB TLS plaintext
buffer for initial cleartext socket reads. After a completely full read, B
attempts a 64 KiB allocation; failure leaves the inline buffer usable. The
allocation lasts until connection close. After finishing a cleartext unary
request, B frees its assembled input rather than retaining it until the
response stream closes. TLS keeps separate socket and plaintext buffers and
its existing request lifetime. HTTP/2 windows, write batching and payload
validation are identical in A and B.

Same host, C++ client, CPU placement and timing contract as the parent report.
Each row is the median of four fresh, alternating pairs for the final binaries.
RSS is the median of process lifetime `VmHWM` values, not a sum of buffer
capacities. CPU µs/RPC includes process user and system CPU, as before.
`rounds.jsonl`: 96 unprofiled runs, 12,717,290 successful RPCs.

| Transport / connections | Request → response | RPC/s A → B | P99 ms A → B | CPU µs/RPC A → B | Peak RSS MiB A → B |
| --- | --- | ---: | ---: | ---: | ---: |
| Plain / 32 | 1 MiB → 64 B | 3,062 → 3,262 | 11.69 → 10.92 | 239 → 227 | 41.8 → 43.7 |
| Plain / 32 | 64 B → 1 MiB | 2,583 → 2,556 | 13.80 → 13.94 | 333 → 337 | 89.3 → 88.5 |
| Plain / 32 | 1 MiB → 1 MiB | 1,447 → 1,585 | 24.34 → 23.53 | 553 → 501 | 83.3 → 76.4 |
| Plain / 32 | 1 KiB → 1 KiB | 135,366 → 135,782 | 0.30 → 0.30 | 4.75 → 4.71 | 7.6 → 7.4 |
| Plain / 128 | 1 MiB → 64 B | 2,586 → 2,698 | 53.94 → 50.87 | 293 → 284 | 141.9 → 148.8 |
| Plain / 128 | 64 B → 1 MiB | 2,236 → 2,246 | 65.23 → 64.46 | 392 → 390 | 354.2 → 353.4 |
| Plain / 128 | 1 MiB → 1 MiB | 1,213 → 1,192 | 113.39 → 110.90 | 672 → 690 | 220.9 → 226.7 |
| Plain / 128 | 1 KiB → 1 KiB | 134,169 → 135,103 | 1.12 → 1.11 | 4.75 → 4.72 | 11.6 → 10.8 |
| TLS / 32 | 1 MiB → 64 B | 2,157 → 2,151 | 16.04 → 16.08 | 379 → 379 | 49.4 → 49.4 |
| TLS / 32 | 64 B → 1 MiB | 1,613 → 1,603 | 21.23 → 21.34 | 508 → 514 | 99.0 → 99.2 |
| TLS / 32 | 1 MiB → 1 MiB | 970 → 973 | 35.67 → 35.27 | 839 → 836 | 91.3 → 96.9 |

**Mechanism:** A separate 32-connection, 2 s, zero-warmup diagnostic counted
`io_uring:io_uring_submit_req` events filtered to `IORING_OP_RECV` on all
server threads, including connection setup and teardown during the client run.
`counts.jsonl` records 65.2 versus 28.0 submissions per completed large upload.
This is a count of socket receives, not HTTP/2 frames, kernel stalls or bytes
copied. A 32 KiB candidate only improved the 32-connection upload by 2.7%.
Growing reads without early request-body release raised peak RSS from 215 to
268 MiB in an earlier 128-connection symmetric run. The final implementation
reduces that penalty but does not outperform A on throughput in that cell.

Reproduce with the parent report's client and `run.py`:

```sh
BENCH_WORKERS=32 python3 run.py "$BENCH" "$A" "$CLIENT" "$OUT" ab "$B" selected
# Repeat with 128 workers for the pressure case and tls-ab / 32 for TLS.
```

Measured executable SHA-256:
`4242b6228b0645e08dbd72446d045b277c0a4e9d10a64123d603c82c2660b21a`
(A), `75c92be915c6a107c67b5d7b578a2c0aed14fc1938b6ed0958bf5a175bfc93b8`
(B). Machine-local logs and exploratory runs: `/tmp/opencode/grpc-recv-RHWA2D6B/`.
