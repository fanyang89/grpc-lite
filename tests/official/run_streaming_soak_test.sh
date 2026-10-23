#!/usr/bin/env bash
set -euo pipefail

unset STREAMING_SOAK_MODE STREAMING_SOAK_DURATION_SECONDS STREAMING_SOAK_TIMEOUT_SECONDS STREAMING_SOAK_SEED
# shellcheck source=tests/official/run_streaming_soak.sh
source "$(dirname "${BASH_SOURCE[0]}")/run_streaming_soak.sh"
configure
[[ "$duration" == 10 && "$overall_timeout" == 300 && "$seed" == 47 ]]
STREAMING_SOAK_MODE=extended configure
[[ "$duration" == 600 && "$overall_timeout" == 1200 ]]
STREAMING_SOAK_DURATION_SECONDS=2 STREAMING_SOAK_TIMEOUT_SECONDS=40 STREAMING_SOAK_SEED=0 configure
[[ "$duration" == 2 && "$overall_timeout" == 40 && "$seed" == 0 ]]

for pair in 010:10 08:8 0:0 000000000:0 000000008:8 999999999:999999999; do
  STREAMING_SOAK_SEED=${pair%:*} configure
  [[ "$seed" == "${pair#*:}" ]]
done

invalid_configurations=(
  STREAMING_SOAK_MODE=invalid
  STREAMING_SOAK_DURATION_SECONDS=0
  STREAMING_SOAK_DURATION_SECONDS=01
  STREAMING_SOAK_DURATION_SECONDS=-1
  STREAMING_SOAK_DURATION_SECONDS=1s
  STREAMING_SOAK_DURATION_SECONDS=999999
  STREAMING_SOAK_TIMEOUT_SECONDS=40
  STREAMING_SOAK_TIMEOUT_SECONDS=garbage
  STREAMING_SOAK_SEED=-1
  STREAMING_SOAK_SEED=1000000000
  STREAMING_SOAK_SEED=18446744073709551616
)
for assignment in "${invalid_configurations[@]}"; do
  if (export "${assignment?}"; configure) >/dev/null 2>&1; then
    printf 'accepted invalid configuration: %s\n' "$assignment" >&2
    exit 1
  fi
done

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
work_dir=$test_dir
printf '%s\n' 'unrelated startup line' 'grpc-lite interop server listening on 127.0.0.1:12345' >"$work_dir/server.log"
[[ $(read_peer_port) == 12345 ]]
for port in 0 65536 999999999999 invalid '12345 trailing'; do
  printf 'grpc-lite interop server listening on 127.0.0.1:%s\n' "$port" >"$work_dir/server.log"
  if read_peer_port; then
    printf 'accepted invalid readiness port: %s\n' "$port" >&2
    exit 1
  fi
done
# Execute the real entrypoint in a temporary project layout. Invalid inputs must
# stop before any build, and must replace success artifacts from an earlier run.
fixture_root="$test_dir/project"
mkdir -p "$fixture_root/tests/official"
runner="$fixture_root/tests/official/run_streaming_soak.sh"
cp "$project_root/tests/official/run_streaming_soak.sh" "$runner"
fixture_logs="$fixture_root/.zig-cache/official/streaming-soak"
for previous in absent success; do
  for assignment in "${invalid_configurations[@]}"; do
    rm -rf "$fixture_logs"
    if [[ "$previous" == success ]]; then
      mkdir -p "$fixture_logs"
      for log in harness build server client; do
        printf 'PASS old success\nharness_exit=0\n' >"$fixture_logs/$log.log"
      done
    fi
    status=0
    env "$assignment" bash "$runner" >"$test_dir/output.log" 2>&1 || status=$?
    [[ "$status" == 2 ]]
    grep -q 'must' "$fixture_logs/harness.log"
    grep -qx 'harness_exit=2' "$fixture_logs/harness.log"
    if grep -qE 'PASS|harness_exit=0' "$fixture_logs/harness.log"; then
      printf 'stale success artifact for %s\n' "$assignment" >&2
      exit 1
    fi
    cmp "$test_dir/output.log" "$fixture_logs/harness.log"
    for log in build server client; do
      [[ -f "$fixture_logs/$log.log" && ! -s "$fixture_logs/$log.log" ]]
    done
  done
done

# Internal dispatch must not initialize/truncate artifacts a second time.
# Stub only the heavy workload; exercise main's real --run/configuration path.
for log in harness build server client; do
  printf 'outer invocation marker\n' >"$fixture_logs/$log.log"
done
STREAMING_SOAK_SEED=08 bash -c '
  source "$1"
  run_soak() { printf "internal-seed=%s\n" "$seed"; }
  main --run
' _ "$runner" >>"$fixture_logs/harness.log" 2>&1
for log in harness build server client; do
  grep -qx 'outer invocation marker' "$fixture_logs/$log.log"
done
grep -qx 'internal-seed=8' "$fixture_logs/harness.log"
printf '%s\n' 'streaming soak harness unit tests passed'
