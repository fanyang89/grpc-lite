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

for assignment in \
  STREAMING_SOAK_MODE=invalid \
  STREAMING_SOAK_DURATION_SECONDS=0 \
  STREAMING_SOAK_DURATION_SECONDS=01 \
  STREAMING_SOAK_DURATION_SECONDS=-1 \
  STREAMING_SOAK_DURATION_SECONDS=1s \
  STREAMING_SOAK_DURATION_SECONDS=999999 \
  STREAMING_SOAK_TIMEOUT_SECONDS=40 \
  STREAMING_SOAK_TIMEOUT_SECONDS=garbage \
  STREAMING_SOAK_SEED=-1 \
  STREAMING_SOAK_SEED=1000000000; do
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
printf '%s\n' 'streaming soak harness unit tests passed'
