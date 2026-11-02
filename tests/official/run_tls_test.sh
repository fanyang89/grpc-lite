#!/usr/bin/env bash
set -euo pipefail

unset ZIG_TLS_SERVER_PORT GO_TLS_SERVER_PORT
source "$(dirname "${BASH_SOURCE[0]}")/run_tls.sh"
[[ "$zig_server_port" == 0 && "$go_server_port" == 0 ]]

mkdir -p "${TMPDIR:-$HOME/tmp}/pi"
test_dir=$(mktemp -d "${TMPDIR:-$HOME/tmp}/pi/grpc-lite-tls-harness-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
peer_log="$test_dir/peer.log"

for line in \
  'grpc-lite interop server listening on 127.0.0.1:12345' \
  'grpc-lite interop server listening on [::1]:12345' \
  'mTLS interop server listening on 127.0.0.1:12345' \
  '2026/10/13 00:00:00 INFO: [interop] interop server listening on [::]:12345' \
  '2026/10/13 00:00:00 INFO: [interop] interop server listening on 0.0.0.0:12345'; do
  printf '%s\n' 'unrelated startup log' "$line" >"$peer_log"
  [[ $(read_peer_port) == 12345 ]]
done
for line in \
  '' \
  'failed to listen: listen tcp :12345: bind: address already in use' \
  'grpc-lite interop server listening on 127.0.0.1:0' \
  'grpc-lite interop server listening on 127.0.0.1:65536' \
  'grpc-lite interop server listening on 127.0.0.1:999999999999' \
  'grpc-lite interop server listening on 127.0.0.1:not-a-port' \
  'grpc-lite interop server listening on 127.0.0.1:12345 trailing'; do
  printf '%s\n' "$line" >"$peer_log"
  if read_peer_port; then
    printf 'unexpected readiness from log: %s\n' "$line" >&2
    exit 1
  fi
done

# An exited child must fail even if its log contains a readiness line.
printf '%s\n' 'grpc-lite interop server listening on 127.0.0.1:12345' >"$peer_log"
(exit 0) &
peer_pid=$!
wait "$peer_pid"
if wait_for_peer >"$test_dir/failure.log" 2>&1; then
  printf '%s\n' 'an exited peer was accepted as ready' >&2
  exit 1
fi
grep -q 'peer exited' "$test_dir/failure.log"

ZIG_TLS_SERVER_PORT=12345 GO_TLS_SERVER_PORT=23456 \
  bash -c 'source "$1"; [[ "$zig_server_port" == 12345 && "$go_server_port" == 23456 ]]' \
  _ "$(dirname "${BASH_SOURCE[0]}")/run_tls.sh"
printf '%s\n' 'TLS harness unit tests passed'
