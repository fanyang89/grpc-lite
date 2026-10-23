# Trusted generated-C consumer seccomp profile

`moby-default.json` is an **unmodified** copy of Moby's Docker default seccomp
allowlist, pinned to commit `4b8214fc4971e06172938a1f1554ccff6647ee80`:

- Source: https://github.com/moby/profiles/blob/4b8214fc4971e06172938a1f1554ccff6647ee80/seccomp/default.json
- Raw source: https://raw.githubusercontent.com/moby/profiles/4b8214fc4971e06172938a1f1554ccff6647ee80/seccomp/default.json
- SHA-256: `6416b47770785a41ac59073cdc77d9fe98517df2799dc83ef207e622de3053f6`
- License: Apache-2.0, copied verbatim into `LICENSE` from the same commit.

`allow_io_uring.py` verifies this digest before appending a single allow rule for
`io_uring_setup`, `io_uring_enter`, and `io_uring_register`. The upstream default
is `SCMP_ACT_ERRNO`/`EPERM`; it does not list these syscalls. All other syscall,
argument, capability, and architecture rules remain unchanged. No allow-all or
unconfined profile is used. The unit test checks the complete structural delta
and rejects a modified source profile. Updating the pin requires security review,
a new digest, and revalidation of the exact delta, not just downloading `main`.

`tests/consumer/run_cmake_c.sh` applies the derived profile **only** to its trusted
local/CI/release consumer container. That container still has `--network none`,
the caller's nonroot UID/GID, no additional capabilities, and no privileged mode.
No daemon-wide Docker setting or other job's profile is changed. The io_uring
exception exposes its kernel interface intentionally to exercise the transport;
this is not a production sandbox recommendation or a promise to protect against
hostile io_uring use. Unrelated restrictions are those of this pinned upstream
profile, not whatever default a future installed Docker daemon may ship.

The host must support and permit io_uring too. An unsupported kernel or additional
host/outer-container policy can still fail tests; the harness does not skip them
or fall back to unconfined execution. The externally isolated host route
(`GRPC_LITE_NETWORK_ISOLATED=1`) retains its pre-existing execution policy and must
supply io_uring permission itself.

Validation:

```bash
python3 -B tests/consumer/seccomp/test_profile.py
python3 tests/consumer/seccomp/allow_io_uring.py /tmp/consumer-seccomp.json
```
