---
title: Resource limits
description: Admission budgets, buffer limits, and ownership boundaries.
---

# Resource limits

Admission limits bound retained work, not total process memory. Configured buffer
capacity is permission to retain bytes, not eager allocation. Queue occupancy,
allocator storage and RSS are different measurements.

## Client admission

Each Channel has independent unary and streaming budgets:

| Budget | Default | Released when |
| --- | --- | --- |
| Retained unary calls | 4096 calls, 64 MiB logical request bytes | Operation storage is released after callback return or blocking result copy |
| Retained streams | 1024 streams, 1 GiB configured inbound + outbound capacity | Both application and transport ownership end |

Unary charge includes path bytes, the 5-byte message header, uncompressed payload,
and raw metadata keys/values. It excludes responses and compression workspace.
A separately owned result may survive reservation release.

Default streaming capacities are 8 MiB in each direction, so the byte budget permits
64 default streams. Terminal status, half-close and Channel teardown do not release
application-retained stream reservations. The backing allocator must outlive the last
stream handle. Failed construction rolls reservations back.

The optional `grpc_lite_async` streaming adapter also retains one application-side
decoded-message slot (at most `max_message_size` payload bytes) and copied metadata.
This is additional to transport capacities and excluded from transport admission
and occupancy counters. It pauses delivery until the slot is consumed; returned
owned messages are separately managed caller storage. See [task-friendly clients](zig-async.md#buffers-allocation-and-ownership).

See [Zig admission](zig-api.md#unary-admission) and
[C/C++ managed channels](c-cpp-reference.md#managed-channels) for configuration and errors.

## Buffers and server limits

| Limit | Default | Scope |
| --- | --- | --- |
| Streaming message size | 4 MiB | Uncompressed message |
| Inbound / outbound stream capacity | 8 MiB / 8 MiB | Each direction of each stream |
| Unary request / response size | 4 MiB / 4 MiB | Individual request or response |
| Server connections | 1024 | Across server reactors |
| Server concurrent streams | 100 | Per connection |
| Cleartext preface timeout | 10 seconds | Absolute initialization deadline |
| Idle timeout | 5 minutes | Only while no inbound RPC streams are active |

A full outbound queue returns retryable `WouldBlock`; wait for writable notification.
Receive pause defers flow-control credit. Inbound overflow fails the RPC with
`RESOURCE_EXHAUSTED`. Message limits and buffer capacities must be configured together;
each stream capacity must be at least `max_message_size + 5`.

Server connection slots remain occupied through asynchronous closing and final
destruction. Transport stream admission ends separately from application-retained
`ServerCall` ownership. Release every retained server call before destroying the Server.
Active RPCs are exempt from the idle timeout; use RPC deadlines for stalled work.

The optional task server has a separate `grpc_lite_async.ServerOptions.max_calls`
budget (default 1024) across reactors. It includes calls whose handlers are still
unwinding after transport termination; excess calls receive `RESOURCE_EXHAUSTED`.
`activeCalls()` reports this retained count. Each admitted call adds one decoded
inbound message slot, capped at `transport.stream_limits.max_message_size`, and a
request-metadata snapshot outside transport counters. Unary handlers also retain
their request until return. Task stacks, returned messages, typed arenas, and
application allocations are not covered by this count budget.

## Memory and ownership

Admission excludes allocator overhead, spare container capacity, metadata/HPACK,
compression and decoder workspace, TLS and dependency allocations, application queues,
thread stacks and kernel socket buffers. More Channels multiply independent budgets;
server stream limits do not provide a global byte budget.

Destroy C result/metadata/stream handles explicitly; C++ RAII adds its own string,
metadata and protobuf storage. Callbacks must not block transport threads. Cross-thread
server work retains an owning `ServerCall`, never a borrowed `ServerStream`.

Queue drain or allocation release need not immediately reduce RSS. Operational snapshots
measure documented logical values, not a deduplicated heap total. See
[operational snapshots](zig-api.md#operational-snapshots) and
[capacity tuning](capacity-tuning.md) for diagnosis and sizing.
