#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$project_root/.zig-cache/official"
grpc_commit=8542e01ff47eb07247ff6cfbd545f3b6f4e9b5d3
image=grpc-lite-http2-edge:${grpc_commit:0:8}-py311-v1
dockerfile="$project_root/third_party/grpc-http2-test/Dockerfile"
container_base_port=40000
base_port=${HTTP2_EDGE_BASE_PORT:-}
container_name="grpc-lite-http2-edge-$$"
server_log="$work_dir/http2-edge-server.log"
server_pid=

cases=(
  data_frame_padding
  goaway
  max_streams
  no_df_padding_sanity_test
  ping
  rst_after_data
  rst_after_header
  rst_during_data
)

if [[ -n "$base_port" ]]; then
  if [[ ! "$base_port" =~ ^[1-9][0-9]{0,4}$ ]] || ((base_port + ${#cases[@]} - 1 > 65535)); then
    printf '%s\n' 'HTTP2_EDGE_BASE_PORT must leave room for all eight ports in 1..65535' >&2
    exit 2
  fi
fi

# Docker reserves the published loopback ports, without a bind/close selection
# race or collisions with the host's ephemeral client ports. An explicit base
# retains the old fixed-host-port override for local debugging.
publish_args=()
for index in "${!cases[@]}"; do
  host_port=
  if [[ -n "$base_port" ]]; then host_port=$((base_port + index)); fi
  publish_args+=(--publish "127.0.0.1:$host_port:$((container_base_port + index))/tcp")
done

stop_server() {
  if [[ -n "$server_pid" ]]; then
    docker stop --time 2 "$container_name" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
  fi
}

cleanup() {
  stop_server
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work_dir"

printf '%s\n' 'Building grpc-lite HTTP/2 edge-case client...'
(cd "$project_root" && zig build)

printf '%s\n' 'Building vendored official gRPC HTTP/2 edge-case server...'
image_id=$(docker build --quiet --file "$dockerfile" --tag "$image" "$project_root")

printf '%s\n' 'Starting vendored official gRPC HTTP/2 edge-case server...'
docker run --rm \
  --name "$container_name" \
  --network bridge \
  "${publish_args[@]}" \
  "$image_id" \
  --host=0.0.0.0 \
  --base_port="$container_base_port" >"$server_log" 2>&1 &
server_pid=$!

ready=false
for _ in {1..200}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$server_log" >&2
    exit 1
  fi
  # Published proxy sockets alone do not prove the backend is listening. Inspect
  # listeners inside the namespace without opening extra connections: the GOAWAY
  # fixture intentionally counts connections and must not receive readiness probes.
  if docker exec "$container_name" python -c '
import sys
from pathlib import Path
ports = {int(row.split()[1].rsplit(":", 1)[1], 16)
         for row in Path("/proc/net/tcp").read_text().splitlines()[1:]
         if row.split()[3] == "0A"}
base, count = map(int, sys.argv[1:])
sys.exit(not set(range(base, base + count)).issubset(ports))
' "$container_base_port" "${#cases[@]}" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 0.05
done

if [[ "$ready" != true ]]; then
  printf '%s\n' 'timed out waiting for all HTTP/2 edge-case listeners' >&2
  cat "$server_log" >&2
  exit 1
fi

for index in "${!cases[@]}"; do
  test_case=${cases[$index]}
  mapping=$(docker port "$container_name" "$((container_base_port + index))/tcp")
  if [[ ! "$mapping" =~ ^127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] || ((BASH_REMATCH[1] > 65535)); then
    printf 'invalid loopback port mapping: %s\n' "$mapping" >&2
    exit 1
  fi
  port=${BASH_REMATCH[1]}
  printf '[ RUN  ] %-26s official HTTP/2 edge-case server\n' "$test_case"
  if "$project_root/zig-out/bin/grpc-lite-interop-client" \
    --server_host=127.0.0.1 \
    --server_port="$port" \
    --test_case="$test_case" \
    --use_tls=false; then
    printf '[ PASS ] %-26s official HTTP/2 edge-case server\n' "$test_case"
  else
    printf '[ FAIL ] %-26s official HTTP/2 edge-case server\n' "$test_case" >&2
    cat "$server_log" >&2
    exit 1
  fi
done

stop_server
if grep -Eq 'AssertionError|Unhandled Error' "$server_log"; then
  printf '%s\n' 'official HTTP/2 edge-case server reported an assertion failure' >&2
  cat "$server_log" >&2
  exit 1
fi
printf '%s\n' 'All 8 official HTTP/2 edge-case server runs passed.'
