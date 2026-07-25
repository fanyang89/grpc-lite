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
| gRPC HTTP/2 framing | `TestSoonClientShortSettings`, `TestSoonShortPreface`, `TestSoonUnknownFrameType`, `TestSoonClientPrefaceWithStreamId`, `TestSoonAllSettingsFramesAcked` | Pass |
| gRPC HTTP/2 framing | `TestSoonSmallMaxFrameSize` | Server GOAWAY passes the repository test; pinned upstream parser cannot recognize GOAWAY frames |
| gRPC HTTP/2 TLS framing | TLS application protocol, version, and cipher suite cases | Skipped; TLS is out of scope |
| gRPC HTTP/2 edge-case server | reset, GOAWAY, ping, max-stream, and DATA padding cases | Pass |
| grpc-go client to grpc-lite server | `rpc_soak`, `channel_soak` | Pass with the official default configuration |
| grpc-lite client to grpc-go server | `rpc_soak`, `channel_soak` | Pass with the official default configuration |

The HTTP/2 framing tool deliberately treats every `TestSoon*` failure as non-fatal.
`run_http2.sh` therefore validates five required non-TLS passes, three expected TLS
skips, and the single named `TestSoonSmallMaxFrameSize` upstream harness limitation.
The repository raw server test independently verifies that an invalid
`SETTINGS_MAX_FRAME_SIZE` receives GOAWAY with `NGHTTP2_PROTOCOL_ERROR`. The complete
upstream report is stored in `.zig-cache/official/http2-framing.log`; the official
framing suite is not reported as fully passing while the pinned parser limitation
remains.

The unary harness defaults to 10 iterations for each soak case. Set `SOAK_ITERATIONS`,
`SOAK_MAX_FAILURES`, and `SOAK_OVERALL_TIMEOUT_SECONDS` to override both directions'
soak settings for scheduled runs. The scheduled soak covers grpc-lite Server reuse and
grpc-lite Channel reuse and recreation.

The edge-case server sources and container image are pinned to the same grpc commit.
The upstream server still contains Python 2 idioms, so the harness applies
`http2-test-python3.patch`, which only updates Python compatibility without changing test
behavior. Docker is required for this suite. The pinned image is amd64-only, so CI runs
this suite on x64 while running the remaining interoperability suites on both x64 and
arm64.
