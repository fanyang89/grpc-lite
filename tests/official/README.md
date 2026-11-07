# Official Interoperability

The official test dependencies are pinned in `go.mod`, `build.zig.zon`, and
`third_party/grpc-http2-test`. Run the suites from the repository root:

```bash
mise run interop-official
mise run interop-async
mise run interop-http2
mise run interop-http2-edge
```

The TLS harness defaults both peers to port zero, lets the kernel assign ports, and
reads each actual port from that peer's startup log before probing readiness.
`ZIG_TLS_SERVER_PORT` and `GO_TLS_SERVER_PORT` still override the defaults; an occupied
explicit port fails rather than silently choosing another port. The harness runs
`bash tests/official/run_tls_test.sh` to validate readiness-log parsing and failed-peer
handling before starting interoperability cases.

## Current Matrix

| Peer or suite | Cases | Result |
| --- | --- | --- |
| grpc-go client to grpc-lite server | `empty_unary`, `large_unary`, `special_status_message`, `unimplemented_method`, `unimplemented_service` | Pass |
| grpc-lite client to grpc-go server | `empty_unary`, `large_unary`, `special_status_message`, `unimplemented_method`, `unimplemented_service` | Pass |
| grpc-go client to grpc-lite server | `client_streaming`, `server_streaming`, `ping_pong`, `empty_stream` | Pass |
| grpc-lite client to grpc-go server | `client_streaming`, `server_streaming`, `ping_pong`, `empty_stream` | Pass |
| grpc-go client to generated C++ server | `client_streaming`, `server_streaming`, `ping_pong`, `empty_stream` | Pass |
| generated C++ client to grpc-go server | `client_streaming`, `server_streaming`, `ping_pong`, `empty_stream` | Pass |
| dedicated grpc-go client to grpc-lite and generated C++ servers | `half_duplex` | Pass; responses begin after the client half-closes |
| grpc-go client to grpc-lite server | `cancel_after_begin`, `cancel_after_first_response`, `timeout_on_sleeping_server` | Pass |
| grpc-lite client to grpc-go server | `cancel_after_begin`, `cancel_after_first_response`, `timeout_on_sleeping_server` | Pass |
| dedicated grpc-go gzip client to grpc-lite server | `identity_unary`, `gzip_request`, `gzip_response`, `identity_expectation_error`, `gzip_expectation_error`, `unsupported_request_encoding` | Pass; verifies identity/gzip request and response negotiation plus mismatch and unsupported-encoding statuses |
| grpc-lite client to dedicated grpc-go gzip server | `client_compressed_unary`, `server_compressed_unary` | Pass; verifies identity/gzip request and response negotiation plus the request-compression mismatch status |
| grpc-go TLS client to grpc-lite TLS server | `empty_unary`, `large_unary`, `client_streaming`, `server_streaming`, `ping_pong`, `empty_stream` | Pass |
| grpc-lite TLS client to grpc-go TLS server | `empty_unary`, `large_unary`, `client_streaming`, `server_streaming`, `ping_pong`, `empty_stream` | Pass |
| gRPC HTTP/2 framing | `TestSoonClientShortSettings`, `TestSoonShortPreface`, `TestSoonUnknownFrameType`, `TestSoonClientPrefaceWithStreamId`, `TestSoonSmallMaxFrameSize`, `TestSoonAllSettingsFramesAcked` | Pass |
| gRPC HTTP/2 TLS framing | `TestSoonTLSApplicationProtocol`, `TestSoonTLSMaxVersion`, `TestSoonTLSBadCipherSuites` | Pass; TLS 1.2+ with `h2` and only ephemeral AEAD cipher suites |
| gRPC HTTP/2 edge-case server | reset, GOAWAY, ping, max-stream, and DATA padding cases | Pass |
| grpc-go client to grpc-lite server | `rpc_soak`, `channel_soak` | Pass with the official default configuration |
| grpc-lite client to grpc-go server | `rpc_soak`, `channel_soak` | Pass with the official default configuration |
| grpc-go client to zio task server | Required cleartext unary/streaming profile, half-duplex, cancellation/deadline, metadata/status, gzip, and soak | Pass with one zio executor |
| dedicated grpc-go tests to zio task server | Compressed input, mixed identity/gzip output, handler wait isolation, cancellation, and response intervals | Pass |

The HTTP/2 framing tool deliberately treats every `TestSoon*` failure as non-fatal.
`run_http2.sh` runs its cleartext framing and TLS profile modes, then validates six
required framing passes and three required TLS passes. The framing module remains pinned at
`github.com/grpc/grpc/tools/http2_interop@v0.0.0-20260718051024-8542e01ff47e`, from grpc
commit `8542e01ff47eb07247ff6cfbd545f3b6f4e9b5d3`. The harness downloads the selected
module, verifies its path, version, checksum, source directory, and expected files, then
copies it into `.zig-cache` and applies two narrow patches: `http2_interop_go1.26.patch`
accepts current Go TLS error text and bounds the bad-cipher probe to TLS 1.2 because Go's
`CipherSuites` setting does not control TLS 1.3, while `http2_interop_goaway.patch` adds
the missing `GoAwayFrame` parser dispatch, accepts parsed GOAWAY for existing negative
framing checks, and requires it for `TestSoonSmallMaxFrameSize`. The repository raw server
test independently verifies that an invalid `SETTINGS_MAX_FRAME_SIZE` receives GOAWAY with
`NGHTTP2_PROTOCOL_ERROR`. The complete upstream report is stored in
`.zig-cache/official/http2-framing.log`.

The official harness defaults to 10 iterations for each soak case. Set `SOAK_ITERATIONS`,
`SOAK_MAX_FAILURES`, and `SOAK_OVERALL_TIMEOUT_SECONDS` to override both directions'
soak settings for scheduled runs. The scheduled soak covers grpc-lite Server reuse and
grpc-lite Channel reuse and recreation.

The edge-case server sources are vendored from the pinned grpc commit with Python 3
compatibility fixes applied. Its complete Python runtime closure is stored as hash-locked
wheels for Linux x86_64 and aarch64. The harness builds a minimal local image from a
multi-architecture Python base pinned by manifest digest; it does not depend on the
upstream interop image registry or a live grpc checkout. Docker is required for this
suite. See `third_party/grpc-http2-test/UPSTREAM.md` for provenance and update rules.

### Mutual TLS

`mise run interop-tls` also tests native Zig client/server mutual TLS against
grpc-go: client identity presentation, required client verification, rejection of
missing/untrusted/expired identities, and unary/streaming calls to a grpc-go mTLS
server. Test-only client credentials live in `src/testdata/mtls`; regenerate them
with `bash src/testdata/mtls/generate.sh` (OpenSSL required). Never deploy these keys.

## Task-handler interoperability

`mise run interop-async` selects the task-server mode of `run_unary.sh`
(`INTEROP_SERVER_MODE=task`). It builds `grpc-lite-task-interop-server` with
`-Dzio=true` and uses the pinned grpc-go clients against raw unary and typed
streaming task handlers on **one executor**. It covers 23 interop cases, including
`custom_metadata`, `status_code_and_message`, and the existing gzip negotiation
checks, then runs four dedicated grpc-go tests in `task_server`.

The dedicated tests verify compressed request frames and mixed compressed/identity
response frames, exercise cancellation/deadlines during a delayed response, and
check that unrelated unary work can progress while another handler is suspended.
The task fixture honors `ResponseParameters.interval_us` with `Io.sleep`.
Half-duplex response specifications are bounded to 4096 entries; response payloads
are allocated only when sent.

Task logs and Go binaries live under `.zig-cache/official/task`. Individual harness
commands have a 30-second timeout, configurable via `INTEROP_CASE_TIMEOUT_SECONDS`;
increase it when increasing the existing `SOAK_*` settings. The dedicated Go tests
have their own 25-second suite timeout. This task-server suite exercises cleartext
server behavior; the callback/C++ and TLS matrices retain their separate entry points.
