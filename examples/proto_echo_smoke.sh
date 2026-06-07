#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/build}"
PORT="${2:-}"

if [[ -z "${PORT}" ]]; then
  PORT="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
fi

SERVER_BIN="${BUILD_DIR}/grpc_lite_proto_echo_server"
CLIENT_BIN="${BUILD_DIR}/grpc_lite_proto_echo_client"

if [[ ! -x "${SERVER_BIN}" ]] || [[ ! -x "${CLIENT_BIN}" ]]; then
  printf 'missing struct_proto26 echo binaries in: %s\n' "${BUILD_DIR}" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${work_dir}"
}
trap cleanup EXIT

"${SERVER_BIN}" "127.0.0.1:${PORT}" > "${work_dir}/server.log" 2>&1 &
server_pid=$!
sleep 1

output=$("${CLIENT_BIN}" "127.0.0.1:${PORT}" "hello grpc-lite")
printf '%s\n' "${output}"

case "${output}" in
  *"response: hello grpc-lite"*) ;;
  *)
    printf 'unexpected echo response\n' >&2
    exit 1
    ;;
esac
