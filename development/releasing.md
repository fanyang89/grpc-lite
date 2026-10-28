# Releasing

## Pre-tag version consistency

1. Inspect current upstream history, tags and published releases before selecting a
   version. Source checkout versions and GitHub's Latest release can differ.
2. Update `build.zig.zon`, `CMakeLists.txt`, and
   `cmake/grpc_liteConfigVersion.cmake` together. Update concrete release bundle
   examples in `README.md` and `docs/`. Do not change dependency versions incidentally.
3. Run `mise run check-release-version`, `mise run test-release-version`, and
   `mise run check-release-version --tag "$candidate_tag"` for the approved candidate.
4. Run `mise run check-transpiled-c` on native Linux x86_64 and ARM64, and
   `mise run test-consumer-cmake-c` for the no-Zig/offline consumer.
5. Require `mise run check` before pushing. Package from the exact clean candidate
   commit so manifests identify its SHA with `dirty: false`. Review its validation
   before creating a tag or publishing a release.

## Generated C bundles

`mise run transpile-c` generates target-specific runtime/plugin C sources, `zig.h`
and a manifest. `mise run package-transpiled-c` creates the release archive.
Set `GRPC_LITE_TRANSPILED_C_TARGET` to `x86_64-linux-gnu` or `aarch64-linux-gnu`;
use separate `GRPC_LITE_TRANSPILED_C_DIST_DIR` directories to retain both outputs.
The reproducibility check clears its output directory and packages twice with
independent caches. Generated sources are never hand-edited or committed.

The release workflow validates the tag/version agreement, manifest provenance,
both native bundles and their no-Zig consumers before publishing. The version checker
does not create tags or publish releases.
