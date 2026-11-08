# Development

These guides are for contributors and maintainers. Application integration and
runtime contracts live in [user documentation](../docs/index.md).

## Build and validate

```sh
mise install
mise run bootstrap
mise run build
mise run test
mise run check
```

Run `mise run check` before every push. It covers formatting, workflow lint,
Debug/ReleaseSafe builds, package consumers, sanitizers, TLS and interoperability.
See [testing](testing.md) for focused checks and [releasing](releasing.md) for releases.
On shared validation hosts, serialize builds and workloads using the host's configured
validation lock for the whole invocation, for example `flock -x "$VALIDATION_LOCK" mise run check`.

### Dependency downloads

CI, coverage, and soak workflows prepare dependencies before starting their test
jobs. `mise run prepare-dependencies` walks the pinned manifest closure, including
lazy packages and all protoc platforms, downloads archives with bounded retries
for transient network failures, and verifies each package with `zig fetch` on its
extracted contents. Hash mismatches and permanent HTTP errors fail immediately.
Cached archives are revalidated on every run; dependency sources are never patched.

The preparation job checks a fresh build with zio, TLS, and gperftools in a network
namespace without network access, then publishes the verified archives to the
workflow's test jobs. Only package archives are cached, keyed by the toolchain,
manifests, and preparation script; compiled objects are not shared across runners.
An upstream outage therefore fails dependency preparation rather than the test
matrix. Tool installation, Go modules, container images, and apt packages still
use their respective download mechanisms.

To reuse the same verified package closure locally:

```sh
mise run prepare-dependencies
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/dependencies"
export GRPC_LITE_DEPENDENCY_CACHE="$ZIG_GLOBAL_CACHE_DIR"
mise run test
mise run test-consumer-async
```

`GRPC_LITE_DEPENDENCY_CACHE` also seeds isolated consumers with package archives;
their own lazy dependency resolution, builds, and tests still run independently.

## Documentation ownership

- `docs/` describes current user-facing behavior and is published on the website.
- `development/` contains maintained contributor workflows, excluded from the site.
- `records.md` preserves dated investigations and validation history. Historical pending
  checks are not current project status. Add dated corrections rather than rewriting results.
- `evidence/` preserves measurement artifacts and their provenance. Keep original data
  and checksums intact when reorganizing documentation.

User guides must explain required contracts without requiring readers to consult an
investigation. Link to historical evidence only as optional supporting material.

## Historical records

- [C/C++ validation](c-cpp-validation.md): ABI baseline and generated-C consumer harness.

- [Development baseline archive](records.md): resource accounting
  investigation, streaming-soak measurements, and original execution qualifications.
- [Streaming-soak evidence](evidence/streaming-soak-baseline/README.md)

The October 2026 documentation reorganization moved the evidence bundle without
changing measurement data or reproduction scripts. Only README paths and its entry
in `SHA256SUMS` changed; original artifact hashes remain unchanged.
