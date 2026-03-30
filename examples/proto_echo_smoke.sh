#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-${ROOT_DIR}/build}"

SERVER_BIN="${BUILD_DIR}/grpc_lite_proto_echo_server"
PROTO_FILE="${ROOT_DIR}/proto/echo.proto"

if [[ ! -x "${SERVER_BIN}" ]]; then
  printf 'missing server binary: %s\n' "${SERVER_BIN}" >&2
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

printf 'message: "hello grpc-lite"\n' \
  | protoc --proto_path="${ROOT_DIR}/proto" --encode=demo.EchoRequest "${PROTO_FILE}" \
  > "${work_dir}/request.pb"

perl -0777 -ne 'print pack("CN", 0, length($_)), $_' \
  < "${work_dir}/request.pb" > "${work_dir}/request.grpc"

"${SERVER_BIN}" > "${work_dir}/server.log" 2>&1 &
server_pid=$!
sleep 1

curl --http2-prior-knowledge -sS \
  -D "${work_dir}/headers.txt" \
  --output "${work_dir}/response.grpc" \
  -H 'content-type: application/grpc' \
  -H 'te: trailers' \
  --data-binary @"${work_dir}/request.grpc" \
  http://127.0.0.1:50051/demo.EchoService/Echo

dd if="${work_dir}/response.grpc" of="${work_dir}/response.pb" bs=1 skip=5 status=none

printf -- '--- HEADERS ---\n'
sed -n '1,40p' "${work_dir}/headers.txt"
printf -- '\n--- RESPONSE ---\n'
protoc --proto_path="${ROOT_DIR}/proto" --decode=demo.EchoReply "${PROTO_FILE}" \
  < "${work_dir}/response.pb"
