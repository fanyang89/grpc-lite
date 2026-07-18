# Official Interoperability

The official test dependencies are pinned in `go.mod` and the grpc-proto
submodule. Run the suites from the repository root:

```bash
mise run interop-official
mise run interop-http2
mise run interop-http2-edge
```

## Current Matrix

| Peer or suite | Cases | Result |
| --- | --- | --- |
| grpc-go client to grpc-lite server | `empty_unary`, `large_unary`, `special_status_message`, `unimplemented_method`, `unimplemented_service` | Pass |
| grpc-lite client to grpc-go server | `empty_unary`, `large_unary`, `special_status_message`, `unimplemented_method`, `unimplemented_service` | Pass |
| grpc-lite compression integration | `client_compressed_unary`, `server_compressed_unary` | Pass; grpc-go v1.82.1 does not expose these cases through its interop client |
| gRPC HTTP/2 framing | `TestSoonShortPreface`, `TestSoonUnknownFrameType`, `TestSoonAllSettingsFramesAcked` | Pass |
| gRPC HTTP/2 framing | `TestSoonClientShortSettings`, `TestSoonClientPrefaceWithStreamId`, `TestSoonSmallMaxFrameSize` | Reported non-fatal failures by the upstream `TestSoon` suite |
| gRPC HTTP/2 TLS framing | TLS application protocol, version, and cipher suite cases | Skipped; TLS is out of scope |
| gRPC HTTP/2 edge-case server | reset, GOAWAY, ping, max-stream, and DATA padding cases | Pass |
| grpc-go client to grpc-lite server | `rpc_soak`, `channel_soak` | Pass with the official default configuration |

The HTTP/2 framing tool deliberately treats every `TestSoon*` failure as non-fatal.
`run_http2.sh` validates required passes, expected TLS skips, and the exact known-failure
allowlist before succeeding. The complete report is stored in
`.zig-cache/official/http2-framing.log`; completion must not be presented as all cases
passing while known failures remain.

The unary harness defaults to 10 iterations for each soak case. Set `SOAK_ITERATIONS`,
`SOAK_MAX_FAILURES`, and `SOAK_OVERALL_TIMEOUT_SECONDS` to override the official grpc-go
soak settings for scheduled runs.

The edge-case server sources and container image are pinned to the same grpc commit.
The upstream server still contains Python 2 idioms, so the harness applies
`http2-test-python3.patch`, which only updates Python compatibility without changing test
behavior. Docker is required for this suite. The pinned image is amd64-only, so CI runs
this suite on x64 while running the remaining interoperability suites on both x64 and
arm64.
