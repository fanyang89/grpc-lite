# Initial streaming-soak resource baseline

Three actual default 600s, seed-47 trials at source
`c96ba3bdc65fe446dab9bd40042e070393f288b2`, tree
`105a1b0404f474ab23580129ad7226029340241a`, on 2026-10-23/24.
All invocation/client/harness exits were 0; all passed the **unchanged provisional
screen**, not a statistically calibrated plateau/leak test. See the
[results, phase semantics and tolerances](../../development.md#initial-measured-streaming-baseline).
No workload was rerun to publish this bundle.

## Contents and provenance

- `trial-{1,2,3}/resources-summary.json`, `resources-environment.json`, `invocation.exit`:
  original bytes, including explicit unavailable counters and root-cgroup limits.
- `trial-{1,2,3}/resources.jsonl.gz`: original JSONL bytes in deterministic gzip
  (level 9, empty embedded filename, mtime 0). All 3407 rows/trial are included.
- [upstream.sha256](upstream.sha256): SHA256 of **uncompressed original** resources,
  summaries, environments and invocation exits, using portable relative filenames.
- [metadata.json](metadata.json): selected host/tool/build/allocator/selected-environment
  facts and actual client terminal results, transcribed from retained external records.
  It is derived metadata, **not** an original observer output. Per-trial start/end UTC,
  load averages and cleanup observations are included. Full logs/host captures stay external.
- [aggregate.json](aggregate.json): raw-derived phase/window counts, min/max/medians,
  warmup/steady/idle deltas and cross-trial medians. Handler events come from original
  summaries; client terminal results come from metadata, not from resource samples.
- [recompute.py](recompute.py), [recompute.sql](recompute.sql): independent arithmetic,
  without importing the observer or running any transport/build. SQL was checked with
  DuckDB 1.5.6; portable Python recomputation uses only the standard library.
- [SHA256SUMS](SHA256SUMS): hashes of every other published bundle file, including gzip.
  These detect corruption, not independent publisher authentication.

Original source evidence remains unchanged externally. The publication audit verified
all 10/44/50 entries of the three original artifact manifests. This bundle intentionally
omits full build/client/server/lifecycle logs, process-monitor traces, binaries, tool
paths, unrestricted environment dumps and unrelated processes. It is sufficient to
recompute every reported resource statistic, but not to rerun historical cleanup or
independently recover client throughput from resource rows alone.

### Privacy and redaction

Every original published JSON field and every decompressed row was inspected by schema
and content. They contain numeric resource/timing/identity data, roles/phases and fixed
observer descriptions, not payloads, tokens, hostnames, credentials or private paths.
**No redaction or numeric changes were needed in those original files.** PIDs and
boot-relative start ticks are retained to audit actual process identity; Unix timestamps
are UTC wall-clock metadata, not the monotonic sample clock. `CLK_TCK=100` on this host.

Supplemental metadata is allowlisted rather than a copied environment/host dump:
private cache paths become `${PRIVATE_CACHE}/zig`, `/go-build`, `/go-mod`; the
host-specific session-cgroup path becomes `${SESSION_CGROUP}`. PATH and executable
installation locations are omitted entirely. Commands use `VALIDATION_LOCK`,
`PRIVATE_CACHE` and `DEST` placeholders, not the original host's absolute paths.
The original records are not rewritten; these substitutions affect provenance labels
only, never measured values. Null environment values mean unset, not zero. The selected
optional override capture exists for trials 2/3; trial 1 exports are established by its
lifecycle script, not an equivalent selected-variable JSON capture.

## Recompute and verify (no workload)

From the repository root:

```bash
cd docs/evidence/streaming-soak-baseline
sha256sum -c SHA256SUMS
python3 -B recompute.py > /tmp/streaming-soak-aggregate.json
cmp aggregate.json /tmp/streaming-soak-aggregate.json
# If DuckDB is installed, verify all 30 nonempty phase/third windows independently:
python3 -B recompute.py --duckdb > /tmp/streaming-soak-duckdb.json
cmp aggregate.json /tmp/streaming-soak-duckdb.json
# Direct SQL output (counts, ranges, medians, elapsed bounds):
duckdb -json :memory: < recompute.sql
```

Recomputation verifies upstream hashes, sample schema/counts, stable identities,
ordered samples, matching environment (except timestamp), original summary statistics,
all growth checks and actual invocation exit files. Do not use Python `-O`, which
would disable its assertions. Cross-trial statistics give **one vote per trial**, not
10,221 independent observations; time-series samples and repeated same-seed trials are
correlated. First/last thirds use chronological order, floor(steady_count/3), not SQL
terciles that might assign the remainder differently.

To inspect the upstream bytes without adding uncompressed files to the checkout:

```bash
bundle="$PWD"
scratch="$(mktemp -d)"
for trial in 1 2 3; do
  mkdir "$scratch/trial-$trial"
  gzip -dc "trial-$trial/resources.jsonl.gz" > "$scratch/trial-$trial/resources.jsonl"
  cp "trial-$trial/"*.json "trial-$trial/invocation.exit" "$scratch/trial-$trial/"
done
(cd "$scratch" && sha256sum -c "$bundle/upstream.sha256")
# Inspect $scratch, then remove it when finished.
```

Compression recipe used Python 3.12.13's `gzip.GzipFile(filename='', mode='wb',
compresslevel=9, mtime=0)` over the unchanged raw bytes. The gzip header contains no
source filename or wall clock; exact deflate bytes may depend on zlib version.
Published compressed and uncompressed hashes are both available.

## Reproduce the measurement (separate approved workload window)

Use a clean checkout of the measured revision, the recorded installed tools and
prepopulated private caches. On a new host follow the repository's `mise install` /
`mise run bootstrap` prerequisites **before** measuring; the recorded trials reused
existing installations/caches without install/bootstrap/refetch. Reproduction on
different hardware/software is a new observation, not a promise of identical values.

Workload: `bidi-slow-large-v1`, cleartext IPv4 loopback, one connection / persistent bidi
stream, two requests/batch, eight responses/request, deterministic 1 MiB through
1 MiB+65520-byte messages, 150ms receive pause, 10ms receive delay, fixed 65535-byte
flow-control windows, 8 MiB server outbound capacity. Runner builds ReleaseSafe and
runs existing shell/Python/Go checks serially before peer startup. Each historical
build log recorded shell suites passing, 17 Python tests OK and Go tests passing.
No new injected workload was run for publication; historical synthetic failure-path
coverage belongs to the existing harness tests, not these successful live trials.

For **each separately scheduled trial**, set absolute external paths `PRIVATE_CACHE`
(prepopulated cache root), `VALIDATION_LOCK` (the shared host lock), `DEST` (a new
per-trial evidence directory). Record hardware, OS, tool versions, affinity, nested
cgroups, selected overrides, load and binary hashes as in metadata. Do not interpret
lock ownership as physical host exclusivity. This portable inner recipe preserves
artifacts on failure and refuses to overwrite an earlier trial:

```bash
export PRIVATE_CACHE VALIDATION_LOCK DEST
/usr/bin/timeout --signal=TERM --kill-after=5s 1195s \
  flock -x -w 60 "$VALIDATION_LOCK" bash -eu -o pipefail -c '
    mkdir "$DEST"
    export ZIG_GLOBAL_CACHE_DIR="$PRIVATE_CACHE/zig"
    export GOCACHE="$PRIVATE_CACHE/go-build" GOMODCACHE="$PRIVATE_CACHE/go-mod"
    export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local MISE_AUTO_INSTALL=false
    unset STREAMING_SOAK_DURATION_SECONDS STREAMING_SOAK_TIMEOUT_SECONDS
    unset GOGC GOMEMLIMIT GOMAXPROCS GOFLAGS
    git rev-parse HEAD HEAD^{tree} > "$DEST/revision-before.txt"
    test "$(git rev-parse HEAD)" = c96ba3bdc65fe446dab9bd40042e070393f288b2
    test -z "$(git status --porcelain)"
    date -u +%FT%TZ > "$DEST/start-utc.txt"
    status=0
    STREAMING_SOAK_MODE=extended STREAMING_SOAK_SEED=47 mise run soak-streaming \
      > "$DEST/invocation.log" 2>&1 || status=$?
    printf "%s\n" "$status" > "$DEST/invocation.exit"
    date -u +%FT%TZ > "$DEST/end-utc.txt"
    work=.zig-cache/official/streaming-soak
    cp "$work/"*.log "$work/"resources*.json "$work/resources.jsonl" "$DEST/"
    git rev-parse HEAD HEAD^{tree} > "$DEST/revision-after.txt"
    git status --porcelain > "$DEST/status-after.txt"
    exit "$status"
  '
# Record the actual outer exit immediately; inspect failures before any next invocation.
```

This is a portable reproduction recipe, not a byte-copy of the original wrappers.
Retain lock acquisition/release, outer exit, metadata, binary hashes and cleanup
identities as well as the files above. Outer timeout/SIGKILL can interrupt copying:
preserve the runner directory before another invocation and never infer success from
missing exit evidence. The runner itself has a 1200s overall timeout and 5s kill grace;
the trials 2/3 outer lifecycle ceiling was 1195s+5s, including lock wait, build and copy.
Trial 1 shared one 1385s+5s lifecycle with the earlier 10s smoke; that smoke is excluded
from this three-trial aggregate. All three lifecycle exits were 0 with explicit unlock.
The smoke also passed (`short_run`), but it is not a plateau baseline.

## Qualifications and recorded interruptions

- Before the original lifecycle lock/private-cache exports, a mistaken `zig build
  --help` preflight created ignored build-graph artifacts. It had exited before traffic;
  default/shared-cache effects were not audited. The measured builds/tests/traffic
  were locked, but **full preflight procedural compliance cannot be claimed**.
- A model/provider fetch failure interrupted the trial-1 handoff **after successful
  validation**, not the workload. Recovery checked saved exit files/hashes/raw numbers;
  it did not rerun smoke or trial 1. No failed live trial is hidden or replaced.
- Host: Fedora 44 Server, Ryzen 9 9955HX, 16 cores/32 threads, one NUMA node, RAM
  97,478,316 KiB / swap 8,388,604 KiB. CPU scaling/boost remained enabled. Lifecycle
  allowed CPUs 0–31 / memory node 0; peers' affinity was not separately sampled.
  Session CPU/memory/PID limits were `max 100000`/`max`/`max`; ancestor user PID limit
  251100. Root limits in original observer JSON remain unavailable, not silently
  replaced with nested limits. Build/allocator/tool details are in metadata.
- Same revision/tree/workload/binaries; observer environments differ only in timestamp,
  Go build metadata matches. Trials 2/3 have the same additional two-second process
  monitor (304 snapshots, 299 during client traffic each), absent in trial 1. No owned
  compiler appeared during sampled traffic. Unrelated sleeping compiler/watch processes
  were untouched; external load and sub-cadence activity are not excluded.
- Samples include pause/drain cycles, not precisely aligned batch boundaries. Medians
  may miss peaks, and three ten-minute runs cannot bound long-term growth. RSS includes
  stacks/code/libraries, allocator residency and live objects. Residual idle RSS cannot
  be causally labeled allocator caching without live-allocation evidence.
- Reservations, actual queue occupancy, live heap, client pre-exit idle and server
  post-deinit accounting are unavailable. Configured capacity is not occupancy;
  WouldBlock/resumes are event counts. Kernel memory is not sampled. Both peers were
  absent after runner cleanup, not proven zero-live-heap before exit; normal server
  exit status is not inferred from controlled termination.
- No native Zig client, TLS/mTLS, ARM64, C/C++ bundle, sanitizer, throughput or universal
  leak-free claim. The budgets were not tuned to these observations. Final-tree
  `mise run check` and independent acceptance review remain pending; neither push nor
  PR creation is part of this documentation/evidence pass.
