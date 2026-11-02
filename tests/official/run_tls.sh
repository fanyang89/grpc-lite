#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$project_root/.zig-cache/official"
zig_server_port=${ZIG_TLS_SERVER_PORT:-0}
go_server_port=${GO_TLS_SERVER_PORT:-0}
certificate="$project_root/src/testdata/localhost-cert.pem"
private_key="$project_root/src/testdata/localhost-key.pem"
cases=(empty_unary large_unary client_streaming server_streaming ping_pong empty_stream cancel_after_begin cancel_after_first_response)
peer_pid=
peer_log=
peer_port=
peer_host=127.0.0.1

stop_peer() {
  if [[ -n "$peer_pid" ]]; then
    kill "$peer_pid" 2>/dev/null || true
    wait "$peer_pid" 2>/dev/null || true
    peer_pid=
  fi
}

read_peer_port() {
  local port
  port=$(sed -nE 's/.*interop server listening on (127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):([0-9]+)$/\2/p' "$peer_log" | tail -n 1)
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$port > 0 && 10#$port <= 65535)) || return 1
  printf '%s\n' "$port"
}

wait_for_peer() {
  local port
  local attempt
  for attempt in {1..100}; do
    if ! kill -0 "$peer_pid" 2>/dev/null; then
      printf 'peer exited before accepting TLS connections\n' >&2
      cat "$peer_log" >&2
      return 1
    fi
    if port=$(read_peer_port) && (exec 3<>"/dev/tcp/$peer_host/$port") 2>/dev/null; then
      peer_port=$port
      exec 3>&-
      exec 3<&-
      return 0
    fi
    sleep 0.05
  done
  printf 'timed out waiting for TLS peer readiness\n' >&2
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
    cat "$peer_log" >&2
    return 1
  fi
}

main() {
  trap stop_peer EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  bash "$project_root/tests/official/run_tls_test.sh"
  mkdir -p "$work_dir"
  zig build -Dtls=true
  (cd "$project_root/tests/official" && \
    go build -mod=readonly -o "$work_dir/grpc-go-interop-client" google.golang.org/grpc/interop/client && \
    go build -mod=readonly -o "$work_dir/grpc-go-interop-server" google.golang.org/grpc/interop/server)

  certificate="$project_root/src/testdata/ipv6-cert.pem"
  for peer_host in 127.0.0.1 ::1; do
    for tls_mode in true false; do
      peer_log="$work_dir/grpc-lite-tls-server.log"
      "$project_root/zig-out/bin/grpc-lite-interop-server" \
        --port="$zig_server_port" \
        --host="$peer_host" \
        --use_tls="$tls_mode" \
        --tls_cert_file="$certificate" \
        --tls_key_file="$private_key" >"$peer_log" 2>&1 &
      peer_pid=$!
      wait_for_peer
      zig_server_port=$peer_port
      for test_case in "${cases[@]}"; do
        run_case "grpc-go client -> grpc-lite server ($peer_host TLS=$tls_mode)" "$test_case" \
          "$work_dir/grpc-go-interop-client" \
          --server_host="$peer_host" \
          --server_port="$zig_server_port" \
          --server_host_override=localhost \
          --test_case="$test_case" \
          --use_tls="$tls_mode" \
          --use_test_ca=true \
          --ca_file="$certificate"
      done
      stop_peer

      peer_log="$work_dir/grpc-go-tls-server.log"
      GRPC_GO_LOG_SEVERITY_LEVEL=info "$work_dir/grpc-go-interop-server" \
        --port="$go_server_port" \
        --use_tls="$tls_mode" \
        --tls_cert_file="$certificate" \
        --tls_key_file="$private_key" >"$peer_log" 2>&1 &
      peer_pid=$!
      wait_for_peer
      go_server_port=$peer_port
      for test_case in "${cases[@]}"; do
        run_case "grpc-lite client -> grpc-go server ($peer_host TLS=$tls_mode)" "$test_case" \
          "$project_root/zig-out/bin/grpc-lite-interop-client" \
          --server_host="$peer_host" \
          --server_port="$go_server_port" \
          --test_case="$test_case" \
          --use_tls="$tls_mode" \
          --ca_file="$certificate"
      done
      stop_peer
    done
  done
  peer_host=127.0.0.1
  certificate="$project_root/src/testdata/localhost-cert.pem"
  # Mutual TLS: distinct server and client trust roots, both RPC directions.
  mtls="$project_root/src/testdata/mtls"
  (cd "$project_root/tests/official" && go build -mod=readonly -o "$work_dir/mtls-peer" ./mtls_peer)
  peer_log="$work_dir/grpc-lite-mtls-server.log"
  "$project_root/zig-out/bin/grpc-lite-interop-server" \
    --port="${ZIG_TLS_SERVER_PORT:-0}" --use_tls=true \
    --tls_cert_file="$certificate" --tls_key_file="$private_key" \
    --client_ca_file="$mtls/ca.pem" >"$peer_log" 2>&1 &
  peer_pid=$!
  wait_for_peer
  zig_server_port=$peer_port
  run_case 'grpc-go client -> grpc-lite mTLS server' empty_unary \
    "$work_dir/mtls-peer" --address="localhost:$zig_server_port" \
    --ca="$certificate" --cert="$mtls/client.pem" --key="$mtls/client-key.pem"
  for identity in missing untrusted expired; do
    identity_args=()
    case "$identity" in
      untrusted) identity_args=(--cert="$certificate" --key="$private_key") ;;
      expired) identity_args=(--cert="$mtls/expired-client.pem" --key="$mtls/client-key.pem") ;;
    esac
    if "$work_dir/mtls-peer" --address="localhost:$zig_server_port" --ca="$certificate" "${identity_args[@]}"; then
      printf 'unexpected acceptance of %s client identity\n' "$identity" >&2
      exit 1
    fi
    printf '[ PASS ] rejected %s client identity\n' "$identity"
  done
  stop_peer
  peer_log="$work_dir/grpc-go-mtls-server.log"
  "$work_dir/mtls-peer" --server --address="127.0.0.1:${GO_TLS_SERVER_PORT:-0}" \
    --ca="$mtls/ca.pem" --cert="$certificate" --key="$private_key" >"$peer_log" 2>&1 &
  peer_pid=$!
  wait_for_peer
  go_server_port=$peer_port
  for test_case in "${cases[@]}"; do
    run_case 'grpc-lite mTLS client -> grpc-go server' "$test_case" \
      "$project_root/zig-out/bin/grpc-lite-interop-client" \
      --server_host=127.0.0.1 --server_port="$go_server_port" \
      --test_case="$test_case" --use_tls=true --ca_file="$certificate" \
      --tls_cert_file="$mtls/client.pem" --tls_key_file="$mtls/client-key.pem"
  done

}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
