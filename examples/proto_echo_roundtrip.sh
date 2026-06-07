#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../build"

SERVER="${BUILD_DIR}/grpc_lite_proto_echo_server"
CLIENT="${BUILD_DIR}/grpc_lite_proto_echo_client"

if [[ ! -x "$SERVER" ]] || [[ ! -x "$CLIENT" ]]; then
  echo "ERROR: build the project first (server or client binary missing)" >&2
  exit 1
fi

SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$SERVER" &
SERVER_PID=$!
sleep 0.5

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "ERROR: server failed to start" >&2
  exit 1
fi

echo "--- CLIENT OUTPUT ---"
OUTPUT=$("$CLIENT" 127.0.0.1:50051 "hello grpc-lite roundtrip")
echo "$OUTPUT"

if echo "$OUTPUT" | grep -q "response: hello grpc-lite roundtrip"; then
  echo "--- PASS ---"
else
  echo "--- FAIL: unexpected response ---" >&2
  exit 1
fi
