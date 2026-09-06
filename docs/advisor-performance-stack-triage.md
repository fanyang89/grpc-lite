# Advisor performance stack triage

Status: audit complete for FAN-79

Audit baseline: `origin/main` at `f3c1e4d` after fetching on 2026-09-05

## Decision

Do not merge any `advisor/001` through `advisor/011` branch. The substantive changes
from every worktree are already present on `origin/main`, mostly as patch-equivalent
rebased commits. The worktree branches are cumulative, old-base integration branches;
merging a tip would replay earlier work and bypass the later correctness, resource-limit,
and API changes on `main`.

In this record, **landed** means that the worktree's incremental change has a
patch-equivalent commit on `origin/main` and that its implementation and tests remain in
the current tree. **Adopt/reimplement** would mean an unlanded idea worth rebuilding on
the current tree, **defer** an idea needing more evidence or a prerequisite, and
**discard** an idea that should not be retained. No worktree increment requires adoption
or deferral.

## Per-worktree audit

The correctness column covers behavior and safety, including tests that prevent an
optimization from changing semantics. The optimization column states the intended cost
reduction separately; benchmark validity is treated as evidence quality rather than a
transport optimization.

| Worktree branch (audited head) | Class | `origin/main` evidence | Correctness and safety evidence | Optimization evidence |
| --- | --- | --- | --- | --- |
| `advisor/001-benchmark-contract` (`a53a660`) | **landed** | Patch-equivalent `69f1e18` | Argument validation, exchange-window accounting, stable payload-pattern, and reservoir-extrema tests remain in `benchmarks/client.zig`. | No transport optimization. It makes load shape and reported latency comparable by recording channels, payload entropy, eligible completions, and true extrema. |
| `advisor/002-outbound-queue` (`9fa728b`) | **landed** | Increment maps to `1e1a488` | Server queue tests preserve message order, free only pending messages on cancellation, and retain drained capacity. | Replaces front removal and shifting with a head index, making dequeue constant time. |
| `advisor/003-dirty-connection-flush` (`e6f582c`) | **landed** | Increment maps to `dd19bd9` | FIFO, deduplication, requeue, and safe removal of closing connections are covered in `src/server.zig`. | Flush work visits only connections that have pending output instead of scanning every connection. |
| `advisor/004-server-deadline-heap` (`7fa034b`) | **landed** | Increment maps to `877ae73` plus correctness follow-up `29038c3` | Heap update/removal, equal expiry, destroyed targets, and root-only expiration are tested. `29038c3` specifically keeps a finished stream's deadline until transport retirement. | Replaces repeated server deadline scans with heap scheduling. |
| `advisor/005-coalesced-writes` (`475640f`) | **landed** | Increment maps to `c4fdff9` | Batch split, oversized chunk, single ownership transfer, empty take, and pending-byte watermark cases are tested for client and server paths. | Coalesces small cleartext HTTP/2 output chunks to reduce socket write submissions. |
| `advisor/006-client-deadline-heap` (`d02f269`) | **landed** | Increment maps to `f27f228` plus correctness follow-up `a359134` | Tests cover mixed targets, arbitrary heap removal, waiting/active unary and stream expiry, and loop ownership. `a359134` restores FIFO admission while allowing middle unlink. | Replaces client deadline scans with heap scheduling and keeps waiting-call removal constant time. |
| `advisor/007-async-unary` (`156854b`) | **landed** | Increment maps to `2fda589` and `50dfd95` | The public event-driven unary path tests borrowed result views, exactly-once completion, deadlines, application errors, reentrancy, shutdown, and allocator cleanup. Benchmark slot/window tests remain. | Raw unary benchmarks use the event-driven client API rather than one blocking worker per slot, isolating transport cost. |
| `advisor/008-stack-headers` (`c7dead2`) | **landed** | Increment maps to `bb206be` | Client/server overflow order, all allocation failures, mixed metadata cleanup, and padded/unpadded binary metadata are tested. | Common request/response headers and encoded metadata values use stack-first builders, avoiding heap allocation on the common path. |
| `advisor/009-write-request-pool` (`3773e97`) | **landed** | Increment maps to `a799e01` | Client/server tests cover reuse, LIFO uniqueness, setup failure, callback release, discard release, queue counters, and connection drain. | Reuses transport write descriptors rather than allocating one for every submitted write. |
| `advisor/010-server-reactors` (`357bd79`) | **landed** | Increment maps to `878186e`, `a01b137`, `863440e`, `e84661a`, and `ca53ba1` | Tests cover zero-reactor rejection, registration/startup rollback, ephemeral/fixed binding, shutdown modes, streaming on shards, two/four shard operation, concurrent callbacks, and synchronized assertions. | Adds `SO_REUSEPORT` server reactor sharding and records reactor count in the benchmark contract. |
| `advisor/011-reactor-allocator` (`485d6ec`) | **landed** | Substantive increments map to `bb84415`, `75bf59e`, and `e24e5a2` | Tests verify reactor-local allocation, shared ownership for cross-thread commands, allocation failure, partial initialization, and atomic callback assertions. | Per-reactor transport allocation avoids serializing small owner-thread allocations through the shared backing allocator. |

`advisor/011` also contains `96ecea8` followed by `b8184e0`. They are intentionally not
on `main`: the second commit exactly reverses the first (`git diff --quiet 96ecea8^ b8184e0`
returns success). This temporary TSan experiment has no final-tree effect and is
**discarded**; the final synchronized-assertion patch is the landed `e24e5a2`.

## Evidence and interpretation

The audit used repository objects rather than branch names or commit subjects alone:

```text
git fetch --prune origin
git cherry -v origin/main advisor/<branch>
git range-diff 2757a3a..advisor/011-reactor-allocator 2757a3a..e24e5a2
git diff --quiet 96ecea8^ b8184e0
git show --stat <advisor-or-main-commit>
```

`git cherry` reports every substantive advisor patch with `-`, meaning a stable
patch-equivalent exists upstream. The range diff gives the following ordered mapping;
the only advisor-only commits are the cancelling `96ecea8`/`b8184e0` pair:

```text
4083b56 = 69f1e18    0aad024 = 1e1a488    61c8d0c = dd19bd9
82e0d96 = 877ae73    14d7229 = 29038c3    61b146c = c4fdff9
b9cd898 = f27f228    03189d7 = a359134    2d145ec ~ 2fda589
03b1e64 = 50dfd95    505497a = bb206be    f5b46a2 = a799e01
1410797 = 878186e    9d34e4e = a01b137    a990d7b = 863440e
bc97012 = e84661a    f4e6449 = ca53ba1    48cffd3 = bb84415
959e4c5 = 75bf59e    485d6ec = e24e5a2
```

The `~` entry differs only where intervening `main` work exposed the shared `xev` module
from `src/root.zig`; `git cherry` still identifies the advisor patch as equivalent. The
current source also contains the introduced deadline heaps, dirty queue, stack-first
header builders, write-request pools, async unary API, reactor configuration, local
reactor allocator, benchmark options, and the tests named in the table. Later `main`
commits build on these seams, which is additional reason not to replay a cumulative tip.

## Sequencing if a divergent release line must be reconstructed

There is nothing to apply to current `main`. On a line that predates this stack,
reimplement or cherry-pick the `main` commits in table order, not an advisor branch tip:

1. Establish the benchmark contract (`69f1e18`) before collecting performance evidence.
2. Land the server queue and dirty-flush changes (`1e1a488`, `dd19bd9`).
3. Keep each scheduling optimization with its correctness companion: server heap then
   stream retirement (`877ae73`, `29038c3`), and client heap then FIFO admission
   (`f27f228`, `a359134`).
4. Land write coalescing (`c4fdff9`), event-driven unary plus its benchmark
   (`2fda589`, `50dfd95`), stack-first headers (`bb206be`), and request pooling
   (`a799e01`). Re-run allocation-failure and ownership tests at each allocation change.
5. Land reactor sharding with its benchmark and all concurrency tests (`878186e` through
   `ca53ba1`) before changing allocator ownership.
6. Land the per-reactor allocator and ownership tests (`bb84415`, `75bf59e`), then the
   synchronized assertion cleanup (`e24e5a2`). Do not port `96ecea8` or `b8184e0`.

This order preserves the test oracle before later allocation and concurrency changes. A
divergent line still needs a fresh conflict review; patch equivalence on `main` is not a
promise that old commits can be applied safely elsewhere.

## Safe cleanup of external worktrees

FAN-79 does not remove external worktrees. Cleanup may happen only after this decision is
reviewed, the FAN-79 PR is merged, and each worktree owner confirms it is no longer in
use. Handle one worktree at a time; do not mega-merge, run a bulk deletion loop, use
`git worktree remove --force`, or prune unrelated worktrees.

For each path reported by `git worktree list --porcelain`:

1. From the worktree, run `git status --porcelain=v1 --untracked-files=all`. Stop if it
   prints anything; the owner must preserve or resolve those files.
2. Record `git rev-parse HEAD` and verify it matches the audited head in the table. If it
   moved, repeat the audit before cleanup.
3. Because rebased patch equivalence is not ancestry, preserve a recovery artifact before
   any forced branch deletion, for example:

   ```sh
   git bundle create /owner-approved/archive/advisor-001.bundle \
     advisor/001-benchmark-contract
   git bundle verify /owner-approved/archive/advisor-001.bundle
   ```

4. From the primary worktree, remove that exact path without `--force`:
   `git worktree remove /home/fanmi/tmp/grpc-lite-exec-001`. A refusal is a safety stop,
   not a reason to force removal.
5. Only after the bundle is verified and the worktree is absent, delete its exact local
   branch. `git branch -d` may reject patch-equivalent rebased history; use `-D` only with
   explicit owner approval and the verified bundle.

Repeat with the matching numbered path and branch through `grpc-lite-exec-011`. The
unrelated prunable `pi-subagents/FAN-71-implement-fb481ea-e2a0-s0-t0` worktree is outside
this decision and must not be removed or pruned as part of FAN-79.
