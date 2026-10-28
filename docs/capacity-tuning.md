---
title: Capacity tuning
description: Resource budgets, admission limits, and overload handling.
---

# Measured capacity tuning and overload diagnosis

Use this runbook to choose and verify deployment-specific limits, not to infer a
universal streams-per-core or memory guarantee. The [accounting inventory](development.md#accounting-boundaries)
is the detailed budget/ownership reference; the [measured baseline](development.md#initial-measured-streaming-baseline)
and its [evidence bundle](evidence/streaming-soak-baseline/README.md) remain authoritative.

## Availability and prerequisites

This guide is based on documentation baseline `f054638e08f9f2b89025c50a1e86529b0b4f1f9c`.
**The sibling implementations below are not included in that baseline or by this
documentation change.** Check the deployed source/runtime before using them:

| Surface | Requirement / pinned contract |
| --- | --- |
| Existing unary/stream admission options and snapshots | Available in the baseline: [Zig](zig-api.md#unary-admission), [C/C++](c-cpp-api.md#managed-channels) (ABI 1.7 unary, 1.8 streaming). |
| Zig Channel/Server operational snapshots (#50/#51) | Requires the implementation represented by PR #68, [`b894e5550400e5beb0760a9f6e0ff3a48c5043ee`][zig-stats]. |
| C/C++ operational snapshots | Requires the implementation represented by PR #70, [`14e250329b6ff9cf9fab34297baa007456ae74e2`][c-stats], ABI 1.9 headers **and runtime**. Low-level `grpc_lite` wrappers, not the `grpc::` facade. |
| Raw C++ bounded executor example | Requires PR #67 source at [`87456528be994aedbca85c77984eb4506d1afc9c`][executor], with matching generated-C asset when building without Zig. The example is not present in the baseline. |

Without these dependencies, use admission snapshots, application event/status counters,
connection logs and process sampling; mark operational queue/reconnect/Server metrics
**unavailable**, not zero. Nothing here backfills them into historical soak evidence.

## Work the budgets before raising a limit

All examples below are arithmetic, **not measured capacity recommendations**. KiB/MiB/GiB
mean powers of 1024. Unary and streaming admission are independent, per Channel.

- **Unary:** `charge = path bytes + 5 + uncompressed payload bytes + raw metadata
  key/value bytes`. For `/test.Echo/Unary` (16 bytes), 64 KiB payload and `x-key: value`
  (5 + 5 bytes), charge is `16 + 5 + 65536 + 10 = 65567` bytes. With default limits,
  `min(4096, floor(67108864 / 65567)) = 1023` identical retained operations fit.
  1023 charge 67,075,041 bytes; 1024 would charge 67,140,608, exceeding 64 MiB.
  Small requests can hit the count cap first. Compression does not reduce this charge.
  Construction, reconnect waiting, in-flight work and result copying/callback execution
  all retain the reservation. A callback starting a replacement call still occupies
  its old slot. A separately owned blocking `CallResult` may survive reservation release.
- **Streaming:** charge is configured inbound **plus** outbound capacity, independent
  of payload traffic: default `8 + 8 = 16 MiB`. Thus
  `min(1024, floor(1024 MiB / 16 MiB)) = 64` retained streams fit, even with empty queues.
  Sixty active handles plus four terminal-but-retained handles still reserve 1 GiB;
  another open rejects. Releasing those four after loop ownership ends returns 64 MiB
  and four slots. Half-close, terminal status and Channel teardown alone do not release
  application-held reservations. The backing allocator must outlive final handle destruction.
- **Capacity is not occupancy:** four default streams reserve `4 × 16 = 64 MiB`
  without eagerly allocating it. If each has one queued identity 1 MiB outbound
  message, whole-frame queue charge is `4 × (1048576 + 5) = 4194324` bytes, not 64 MiB.
  Channel operational outbound accounting retains a whole frame through partial
  consumption; Server outbound accounting decreases as bytes are consumed. Neither
  charge is allocation size or total RSS. Draining can leave container capacity resident.
- **Smaller queues change the arithmetic, not proven throughput:** with a 1 MiB
  message limit and 2 MiB in each direction, `1024 / (2 + 2) = 256` streams fit the
  default Channel byte budget. Each direction must be at least `max_message_size + 5`;
  simply reducing buffers below the default 4 MiB message limit is invalid. This says
  nothing about simultaneous server admission: the default is 100 streams per
  connection. More Channels multiply independent budgets: four default Channels permit
  `4 × 1 GiB = 4 GiB` streaming reservations plus `4 × 64 MiB = 256 MiB` unary charges,
  **not** an allocated-memory prediction or shared process cap.

Quota errors are distinct from a full send queue. Zig unary/open return
`UnaryAdmissionRejected` / `StreamAdmissionRejected` without a rejected-call callback.
C/C++ unary reports `RESOURCE_EXHAUSTED`; low-level stream open reports `WOULD_BLOCK`
(`ErrorCode::WouldBlock`), mapped to `RESOURCE_EXHAUSTED` by grpcpp. A successful open
can later return retryable `WouldBlock` on send. Follow writable notification rather
than spinning, blocking a reactor, or growing an unbounded application retry queue.

These boundaries are implemented in [baseline Channel construction/destruction][channel-source]
and [buffer validation][buffer-source]. Existing source tests include
`unary admission enforces exact count and byte boundaries and recovers`,
`stream admission enforces count and capacity reservations`, and
`client stream handle outlives channel teardown`; they are not deployment load tests.

## Tune by controlled comparison

1. **Define the workload and acceptance thresholds first.** Record payload/metadata
   distributions, compression, cardinality, slow-consumer pauses, burst/arrival rate,
   RPC latency/error objectives, acceptable rejection rate, and process/host headroom.
   Pin source, binaries, architecture, allocator, TLS/build mode and tool versions.
   Record CPU affinity/frequency, cgroup limits and background host load. Schedule a
   separate approved measurement window; on a shared host serialize the entire build,
   traffic and cleanup lifecycle using the [existing lock procedure](development.md#streaming-soak).
2. **Collect a baseline with explicit phases.** Reuse [benchmarks](development.md#benchmarks)
   for completion/latency and the [soak observer](development.md#streaming-resource-observer-48)
   for repeated pressure/recovery and RSS/FD/thread samples. Keep startup/warmup,
   early/late steady traffic and post-client idle separate; include overload and recovery
   in deployment tests. Record offered, accepted and completed work plus status and
   business-queue delay, not only throughput. The benchmark is closed-loop: its fixed
   concurrency can hide arrival overload. Unary RPCs and persistent-stream messages
   are different operations; raw and typed unary include different costs.
3. **Sweep Channels, streams and reactors separately.** Start from a small reproducible
   configuration; increase one axis while holding payload, pipeline, queues and deadlines
   fixed. A connection and all its streams stay on one server reactor; increasing streams
   on one Channel cannot distribute that connection across reactors. Use at least as many
   Channels as reactors when testing multi-reactor scaling, but do not assume equal
   `SO_REUSEPORT` distribution. Watch CPU, latency, FDs, threads, admitted connections
   and rejection rates. More reactors add listeners, pools, stacks and caches; more
   Channels add independent budgets and connection costs. Stop increasing when the
   latency/error or resource-headroom objective fails, even if throughput still rises.
4. **Size queues for bursts that can drain within the deadline.** Measure writable-block
   events, queue charges/high-water marks, pause durations and recovery time. Try lower
   per-stream capacities while preserving message validation and observed burst needs;
   recompute aggregate reservations each time. Include gzip and worst allowed messages:
   outbound is encoded bytes, inbound decoded queue charge is payload + 5, and decoder
   storage is separate. Larger queues can defer rejection while increasing latency and
   retained memory; they cannot fix a consumer slower than sustained production.
5. **Budget deadlines end to end.** Allow for connection/reconnect waiting, business
   queueing, service and response drain within the application SLO; measure each rather
   than copying the soak's timeout. Unsubmitted unary calls keep their original deadlines
   during reconnect; recovery does not replay submitted RPCs. Set downstream timeouts
   and cancellation policy too. Server idle timeout applies only with no inbound RPCs,
   not to a stalled active stream. Graceful drain timeout bounds transport shutdown,
   not application worker execution or release of retained handles.
6. **Bound business work independently.** Keep callbacks nonblocking. Bound executor
   worker count, waiting jobs **and retained bytes**; measure service time, queue delay,
   rejection and cancellation. For illustration, four workers plus eight waiting jobs
   retaining at most 256 KiB copied payload each imply at most `12 × 256 KiB = 3 MiB`
   of those copies only, excluding results, retained calls and stacks. This is an
   application budget, not a library option. The [dependency-gated example][executor]
   deliberately uses one worker, one total outstanding job and no waiting backlog;
   `try_lock` contention, full or closed admission rejects immediately. Transfer an
   owning `ServerCall` only on acceptance; never save borrowed `ServerStream` or
   callback context. Close admission, bound/cancel downstream work, drain/join workers
   and release every retained call before Server destruction. The example aborts on
   send failure; it is not a general streaming backpressure implementation.
7. **Repeat and keep the failure evidence.** Compare like-for-like trials, then longer
   runs and relevant production variants. Change no tolerance after seeing the result
   without a separate rationale. Verify recovery after load removal and final owner
   release, not merely successful process exit. Roll back a setting that breaches the
   objective; retain source/configuration, sample timestamps, exits and artifact hashes.

## Read snapshots as ownership samples

The rest of this section **requires the operational-snapshot dependencies above**.
Use Zig `channel.operationalStats()` / `server.operationalStats()`, C
`grpc_lite_channel_get_operational_stats` / `grpc_lite_server_get_operational_stats`
with the matching `GRPC_LITE_*_OPERATIONAL_STATS_INIT`, or low-level C++
`GetOperationalStats`. Check getter errors. The [pinned Zig][zig-stats] and
[C/C++ contracts][c-stats] define every field; table names below use Zig spelling.
C/C++ flatten admission fields with `unary_` / `stream_` prefixes, for example
`stream_admission.reserved_buffer_bytes` becomes `stream_reserved_buffer_bytes`.

Sample with monotonic timestamps and owner identity. Compute event-counter deltas over
an interval only for the same owner; counters saturate and have no reset, and high-water
marks are lifetime values. A new high-water mark is not an interval occupancy average.
Channel operational fields and its two admission snapshots are sampled independently;
Server fields aggregate independent reactor samples, not a global transaction.
Server `*_high_water_sum` adds non-simultaneous reactor peaks, not a true global peak.
Do not enforce exact cross-field identities on live samples.

Getters allocate nothing and return value copies. Sampling may overlap supported
operations, shutdown and wait, including after wait while the owner lives. Stop/join
readers before exclusive owner destruction (or C++ moves); a surviving client stream
handle does **not** make a destroyed Channel queryable. Synchronize shared output storage.

| Symptom | Correlate, then act |
| --- | --- |
| New work rejects | Rising `unary_admission.rejected_calls` / `stream_admission.rejected_streams` identifies Channel quota refusals. Compare retained count **and** charged bytes with configured caps; inspect terminal retained handles before increasing limits. Server `rejected_connections` counts only connection-cap refusals, not drain/init failures. `pre_ack_rejected_streams` covers pre-ACK cap/defensive guard refusals, not generic post-ACK protocol rejections. Use RPC errors/logs and separate executor rejection counters to distinguish header/message limits, allocation failures, drain and business overload. |
| Slow consumer / repeated `WouldBlock` | Correlate `stream_inbound_bytes`, `stream_outbound_bytes`, Server `streaming_outbound_reserved_bytes`, socket gauges, application pause/writable events and completion latency. Inbound counts paused decoded messages, not decoder storage or immediately delivered payload. Server outbound includes queued send commands but excludes unary responses and temporary encodings. Socket gauges include owned in-flight buffers until completion/discard, not peer delivery. Resume consumption or reduce production; enlarge queues only after demonstrating acceptable drain time. |
| Reconnect or deadlines rising | Compare `active_connections`, `pending_unary_calls`, `reconnect_attempts`, `reconnect_successes`, `reconnect_goaway`, `reconnect_transport_failure` and terminal buckets with DNS/connection logs. Attempts count TCP submissions after the initial attempt (including address candidates), not DNS-only failures/backoff scheduling. Trigger counters can overlap and are not a complete failure taxonomy. `terminal_other` combines unavailable, resource exhaustion and application failures. Check peer availability and deadline budget; do not assume replay or retry every failed RPC blindly. |
| Server slots stay occupied | `admitted_connections` includes initialization, drain and asynchronous close until destruction; it differs from Channel usable `active_connections`. `active_rpcs` counts inbound transport entries, including invalid/unhandled requests, not retained `ServerCall` controls after retirement. Correlate `close_*` deltas with logs: the first effective close reason is latched and counted only at final destruction. Idle/preface expiry and forced drain are different lifetimes. |
| RSS grows, active work falls | Compare retained admission, current queue/socket gauges, application results/executor backlog, FDs/threads and post-idle RSS. Terminal client handles can retain reservations and queue bytes even after `wait`; release application owners before expecting current gauges to fall. Lifetime high-water marks never fall. If current gauges return to zero but RSS does not, obtain allocation/live-object evidence rather than calling it either a leak or benign caching. |

**Not a heap budget:** do not sum reserved capacities, stream charges and socket bytes
as a deduplicated memory total. Unbudgeted costs include unary responses and copied
results; metadata/HPACK, decoder and compression workspace; ArrayList spare capacity;
concurrent send temporaries; TLS and dependency allocations (nghttp2/libxev/c-ares);
allocator overhead/caches; C handles and C++/protobuf copies; application queues,
retained server controls, thread stacks and kernel socket buffers. Snapshots omit
live heap, decoder occupancy, business queue depth/latency, CPU and generic post-ACK
stream-cap rejection counts. Add application/process instrumentation for those gaps;
no per-process RSS ceiling follows from transport admission.

## What the existing measurements justify

The [three 600-second seed-47 trials](evidence/streaming-soak-baseline/README.md) cover
one grpc-go client connection and one persistent bidi stream to a native ReleaseSafe,
cleartext x86_64 server, not a Channel/reactor capacity sweep. The unchanged provisional
screen passed in all three. As one worked reading of [aggregate.json](evidence/streaming-soak-baseline/aggregate.json),
trial 1 server early/late RSS medians were 12,300/13,284 KiB: delta `984 KiB`.
Its allowed positive delta was `max(32768, 0.25 × 12300) = 32768 KiB`, not a fitted
capacity or leak threshold. Post-client idle RSS was `4852 − 3764 = 1088 KiB` above
pre-client baseline; this is server-still-alive idle, not Server deinit or attributed cache.

The [metadata](evidence/streaming-soak-baseline/metadata.json) records Ryzen 9 9955HX,
Fedora 44/glibc 2.43, Zig SafeAllocator/page backing plus reactor caches and separate C
allocation paths, and Go's allocator/GC. Hardware, allocator and workload changes require
new comparisons. The host was not physically isolated or frequency-pinned; background
activity was not excluded and trials 2/3 added a process monitor absent from trial 1.
Three fixed-seed correlated ten-minute traces do not establish a long-term plateau,
leak freedom, statistical calibration or a universal maximum. Medians can miss peaks
and slow leaks. Reservations, queue occupancy, live heap, kernel memory, client pre-exit
idle and server post-deinit accounting were not measured. No TLS/mTLS, native-client,
ARM64 or C/C++ capacity claim follows. This guide adds no measurements and does not
replace the pending independent review and exact-final-tree `mise run check` before push.

[zig-stats]: https://github.com/fanyang89/grpc-lite/blob/b894e5550400e5beb0760a9f6e0ff3a48c5043ee/docs/zig-api.md#operational-snapshots
[c-stats]: https://github.com/fanyang89/grpc-lite/blob/14e250329b6ff9cf9fab34297baa007456ae74e2/docs/c-cpp-api.md#operational-snapshots
[executor]: https://github.com/fanyang89/grpc-lite/blob/87456528be994aedbca85c77984eb4506d1afc9c/examples/cpp_bounded_executor/main.cc
[channel-source]: https://github.com/fanyang89/grpc-lite/blob/f054638e08f9f2b89025c50a1e86529b0b4f1f9c/src/channel.zig
[buffer-source]: https://github.com/fanyang89/grpc-lite/blob/f054638e08f9f2b89025c50a1e86529b0b4f1f9c/src/stream.zig
