# Official Interoperability

The official test dependencies are pinned in `go.mod` and the grpc-proto
submodule. Run the suites from the repository root:

```bash
mise run interop-official
mise run interop-http2
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
| gRPC HTTP/2 edge-case server | reset, GOAWAY, ping, max-stream, and DATA padding cases | Not yet integrated |
| grpc-go client to grpc-lite server | `rpc_soak`, `channel_soak` | Pass with the official default configuration |

The HTTP/2 framing tool deliberately treats every `TestSoon*` failure as non-fatal and
returns success unless a non-`TestSoon` case fails. `run_http2.sh` preserves that upstream
exit behavior and stores the complete report in
`.zig-cache/official/http2-framing.log`; completion must not be presented as all cases
passing.
