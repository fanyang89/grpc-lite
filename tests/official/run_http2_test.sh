#!/usr/bin/env bash
set -euo pipefail

unset HTTP2_SERVER_PORT HTTP2_TLS_SERVER_PORT
source "$(dirname "${BASH_SOURCE[0]}")/run_http2.sh"
[[ "$cleartext_port" == 0 && "$tls_port" == 0 ]]

mkdir -p "${TMPDIR:-$HOME/tmp}/opencode"
test_dir=$(mktemp -d "${TMPDIR:-$HOME/tmp}/opencode/grpc-lite-http2-harness-test.XXXXXX")
trap 'stop_server; rm -rf "$test_dir"' EXIT
log_file="$test_dir/server.log"

printf '%s\n' 'unrelated startup log' \
  'grpc-lite interop server listening on 127.0.0.1:12345' >"$log_file"
[[ $(read_server_port "$log_file") == 12345 ]]
for line in \
  '' \
  'error: BindFailed' \
  'grpc-lite interop server listening on 127.0.0.1:0' \
  'grpc-lite interop server listening on 127.0.0.1:65536' \
  'grpc-lite interop server listening on 127.0.0.1:999999999999' \
  'grpc-lite interop server listening on 127.0.0.1:not-a-port' \
  'grpc-lite interop server listening on 127.0.0.1:12345 trailing'; do
  printf '%s\n' "$line" >"$log_file"
  if read_server_port "$log_file"; then
    printf 'unexpected readiness from log: %s\n' "$line" >&2
    exit 1
  fi
done

HTTP2_SERVER_PORT=12345 HTTP2_TLS_SERVER_PORT=23456 \
  bash -c 'source "$1"; [[ "$cleartext_port" == 12345 && "$tls_port" == 23456 ]]' \
  _ "$project_root/tests/official/run_http2.sh"

# Exercise readiness with a real kernel-assigned socket and an occupied port.
project_root="$test_dir"
mkdir -p "$project_root/zig-out/bin"
cat >"$project_root/zig-out/bin/grpc-lite-interop-server" <<'PY'
#!/usr/bin/env python3
import socket
import sys

port = int(next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--port=")))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", port))
    listener.listen()
    print(f"grpc-lite interop server listening on 127.0.0.1:{listener.getsockname()[1]}", flush=True)
    while True:
        connection, _ = listener.accept()
        connection.close()
PY
chmod +x "$project_root/zig-out/bin/grpc-lite-interop-server"
start_server 0 false "$log_file"
[[ "$server_port" -gt 0 ]]
listener_pid=$server_pid
occupied_port=$server_port
trap 'stop_server; kill "$listener_pid" 2>/dev/null || true; wait "$listener_pid" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
if start_server "$occupied_port" false "$test_dir/occupied.log" >"$test_dir/failure.log" 2>&1; then
  printf '%s\n' 'an unrelated listener was accepted as ready' >&2
  exit 1
fi
[[ -z "$server_port" ]]
printf '%s\n' 'HTTP/2 harness tests passed'
