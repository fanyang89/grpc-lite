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
