#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$project_root/.zig-cache/official"
zig_server_port=${ZIG_SERVER_PORT:-$((20000 + $$ % 10000))}
go_server_port=${GO_SERVER_PORT:-$((zig_server_port + 1))}
cases=(
  empty_unary
  large_unary
  special_status_message
  unimplemented_method
  unimplemented_service
)

peer_pid=
peer_log=

stop_peer() {
  if [[ -n "$peer_pid" ]]; then
    kill "$peer_pid" 2>/dev/null || true
    wait "$peer_pid" 2>/dev/null || true
    peer_pid=
  fi
}

cleanup() {
  stop_peer
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_peer() {
  local port=$1
  local attempt
  for attempt in {1..100}; do
    if ! kill -0 "$peer_pid" 2>/dev/null; then
      printf 'peer exited before accepting connections\n' >&2
      printf '%s\n' '--- peer log ---' >&2
      cat "$peer_log" >&2
      return 1
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&-
      exec 3<&-
      return 0
    fi
    sleep 0.05
  done
  printf 'timed out waiting for peer on port %s\n' "$port" >&2
  printf '%s\n' '--- peer log ---' >&2
  cat "$peer_log" >&2
  return 1
}

run_case() {
  local direction=$1
  local test_case=$2
  shift 2
  printf '[ RUN  ] %-24s %s\n' "$test_case" "$direction"
  if "$@"; then
    printf '[ PASS ] %-24s %s\n' "$test_case" "$direction"
  else
    printf '[ FAIL ] %-24s %s\n' "$test_case" "$direction" >&2
    printf '%s\n' '--- peer log ---' >&2
    cat "$peer_log" >&2
    return 1
  fi
}

mkdir -p "$work_dir"

printf '%s\n' 'Building grpc-lite interop binaries...'
(cd "$project_root" && zig build)

printf '%s\n' 'Building grpc-go v1.82.1 interop binaries...'
(cd "$project_root/tests/official" && \
  go build -mod=readonly -o "$work_dir/grpc-go-interop-client" google.golang.org/grpc/interop/client && \
  go build -mod=readonly -o "$work_dir/grpc-go-interop-server" google.golang.org/grpc/interop/server)

peer_log="$work_dir/grpc-lite-server.log"
"$project_root/zig-out/bin/grpc-lite-interop-server" \
  --port="$zig_server_port" --use_tls=false >"$peer_log" 2>&1 &
peer_pid=$!
wait_for_peer "$zig_server_port"
for test_case in "${cases[@]}"; do
  run_case 'grpc-go client -> grpc-lite server' "$test_case" \
    "$work_dir/grpc-go-interop-client" \
    --server_host=127.0.0.1 \
    --server_port="$zig_server_port" \
    --test_case="$test_case" \
    --use_tls=false
done
stop_peer

peer_log="$work_dir/grpc-go-server.log"
"$work_dir/grpc-go-interop-server" \
  --port="$go_server_port" --use_tls=false >"$peer_log" 2>&1 &
peer_pid=$!
wait_for_peer "$go_server_port"
for test_case in "${cases[@]}"; do
  run_case 'grpc-lite client -> grpc-go server' "$test_case" \
    "$project_root/zig-out/bin/grpc-lite-interop-client" \
    --server_host=127.0.0.1 \
    --server_port="$go_server_port" \
    --test_case="$test_case" \
    --use_tls=false
done
stop_peer

printf '%s\n' 'All 10 official unary interop runs passed.'
