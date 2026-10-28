---
title: Profiling and benchmarks
description: Measure application performance and compare representative workloads.
---

# Profiling and benchmarks

## Gperftools

Linux builds can optionally use gperftools for tcmalloc, CPU/heap profiling and guarded
allocation sampling. Prepare the dependency with `mise run prepare-gperftools`.
Downstream Zig packages pass `.gperftools = true` and import `grpc_lite_gperftools`.
By default this also replaces the process C allocator with tcmalloc; `perf.allocator`
exposes it to Zig APIs.

```zig
const perf = @import("grpc_lite_gperftools");

try perf.startCpuProfiler("server.prof");
defer perf.stopCpuProfiler();
```

Pass `.tcmalloc = false` for CPU profiling without allocator replacement, or
`.tcmalloc = true, .gperftools = false` for minimal tcmalloc alone. Heap profiling and
guarded sampling require both options. Profilers are process-global and support
`CPUPROFILE` / `HEAPPROFILE`. Tcmalloc cannot be combined with ThreadSanitizer.

## Benchmarks

From a source checkout:

```sh
mise run bench -- --scenario bidi-ping-pong --transport typed
mise run bench -- --reactors=4 --channels=16 --streams=512
mise run bench-all
```

Scenarios are `unary`, `bidi-ping-pong`, and `bidi-throughput`. Options include
`--warmup`, `--duration`, `--streams`, `--channels`, `--reactors`, `--pipeline`,
`--payload-bytes`, `--payload-pattern`, and `--compression`.
Use `mise run bench-server` and `mise run bench-client` for separately managed peers.
Output is JSON; `--compact` emits one line.

Measurements count completed exchanges after warmup, not send-queue admission.
Bytes are application payload bytes, not HTTP/2 wire bytes. Unary operations are RPCs;
bidirectional operations are messages on persistent streams. Typed unary also includes
protobuf and blocking-worker costs, so raw/typed results are not a pure transport comparison.

The harness is closed-loop with fixed concurrency. Eligible exchanges can finish during
bounded drain; percentiles and mean may use a deterministic reservoir. Keep workload,
hardware, allocator and build settings comparable. Use at least as many Channels as
reactors when measuring multi-reactor scaling. See [capacity tuning](capacity-tuning.md)
for choosing deployment limits rather than extrapolating from one benchmark.
