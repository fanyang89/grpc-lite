#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir="$project_root/.zig-cache/official/streaming-soak"
peer_pid=
client_pid=
resource_observer="$project_root/tests/official/streaming_soak_resources.py"
gnu_timeout_paths=(/usr/bin/timeout /bin/timeout)

select_gnu_timeout() {
  local candidate version
  # Prefer system coreutils over PATH entries that mise tools may shadow.
  for candidate in "${gnu_timeout_paths[@]}" "$(type -P timeout || true)"; do
    [[ -x "$candidate" ]] || continue
    if version=$("$candidate" --version 2>/dev/null) && [[ "$version" == 'timeout (GNU coreutils)'* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf 'GNU coreutils timeout is required (--signal and --kill-after with process-group cleanup); no compatible implementation found\n' >&2
  return 2
}

configure() {
  case ${STREAMING_SOAK_MODE:-smoke} in
    smoke) duration=${STREAMING_SOAK_DURATION_SECONDS:-10}; overall_timeout=${STREAMING_SOAK_TIMEOUT_SECONDS:-300} ;;
    extended) duration=${STREAMING_SOAK_DURATION_SECONDS:-600}; overall_timeout=${STREAMING_SOAK_TIMEOUT_SECONDS:-1200} ;;
    *) printf 'STREAMING_SOAK_MODE must be smoke or extended\n' >&2; return 2 ;;
  esac
  seed=${STREAMING_SOAK_SEED:-47}
  if [[ ! "$duration" =~ ^[1-9][0-9]{0,4}$ || ! "$overall_timeout" =~ ^[1-9][0-9]{0,4}$ || ! "$seed" =~ ^[0-9]{1,9}$ ]]; then
    printf 'duration/timeout must be positive decimal seconds (at most 5 digits); seed must have 1-9 digits\n' >&2
    return 2
  fi
  # Go's uint flag uses base 0. Normalize only after the nine-digit bound above,
  # so leading zeros stay decimal and conversion cannot overflow shell integers.
  seed=$((10#$seed))
  if ((overall_timeout <= duration + 30)); then
    printf 'overall timeout must exceed duration + 30 seconds (allow build/startup/drain time)\n' >&2
    return 2
  fi
}

stop_child() {
  local pid=$1
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT
  stop_child "$client_pid"
  stop_child "$peer_pid"
  if ((status != 0)); then
    for log in build server client; do
      printf '\n--- %s.log (last 80 lines) ---\n' "$log" >&2
      tail -n 80 "$work_dir/$log.log" >&2 || true
    done
  fi
  exit "$status"
}

read_peer_port() {
  local port
  port=$(sed -nE 's/^grpc-lite interop server listening on 127\.0\.0\.1:([0-9]+)$/\1/p' "$work_dir/server.log" | tail -n 1)
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$port > 0 && 10#$port <= 65535)) || return 1
  printf '%s\n' "$port"
}

run_soak() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'coverage=native-linux-%s cleartext grpc-go-client->grpc-lite-server mode=%s duration=%ss seed=%s overall_timeout=%ss\n' \
    "$(uname -m)" "${STREAMING_SOAK_MODE:-smoke}" "$duration" "$seed" "$overall_timeout"
  cd "$project_root"
  {
    bash tests/official/run_streaming_soak_test.sh
    python3 -B -m unittest discover -s tests/official -p 'test_streaming_soak_resources.py'
    zig build streaming-soak-peer -Doptimize=ReleaseSafe
    cd tests/official
    go test -mod=readonly ./streaming_soak
    go build -mod=readonly -o "$work_dir/streaming-soak-client" ./streaming_soak
  } >"$work_dir/build.log" 2>&1
  "$project_root/zig-out/bin/grpc-lite-interop-server" --port=0 --use_tls=false --streaming_soak \
    >"$work_dir/server.log" 2>&1 &
  peer_pid=$!
  local port='' ready=false
  for _ in {1..100}; do
    if ! kill -0 "$peer_pid" 2>/dev/null; then
      printf 'peer exited before readiness\n' >&2
      return 1
    fi
    if port=$(read_peer_port) && (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      ready=true
      break
    fi
    sleep 0.05
  done
  if [[ "$ready" != true ]]; then
    printf 'timed out waiting for peer readiness\n' >&2
    return 1
  fi
  python3 "$resource_observer" observe --directory "$work_dir" --server-pid "$peer_pid" \
    --duration "$duration" --seed "$seed" -- \
    "$work_dir/streaming-soak-client" --target="127.0.0.1:$port" --duration="${duration}s" \
    --timeout="$((duration + 30))s" --seed="$seed" >"$work_dir/client.log" 2>&1 &
  client_pid=$!
  wait "$client_pid"
  client_pid=
  cat "$work_dir/client.log"
  # These counters come from the existing interop handler, not timing guesses.
  # Require repeated pressure AND receive recovery, in addition to exact client
  # response verification and successful half-close/OK terminal status.
  if ! awk '
    /^streaming-soak / {
      split($3, blocked, "="); split($4, resumed, "=");
      if (blocked[2] >= 2 && resumed[2] >= 2) passed = 1;
    }
    END { exit !passed }
  ' "$work_dir/server.log"; then
    printf 'missing repeated server WouldBlock/receive-resume evidence\n' >&2
    return 1
  fi
  cat "$work_dir/server.log"
  printf 'PASS streaming soak including repeated backpressure/recovery\n'
}

main() {
  if [[ ${1:-} == --run ]]; then
    configure
    run_soak
    return
  fi
  mkdir -p "$work_dir"
  # Only the outer invocation initializes artifacts, before even validating
  # configuration: invalid inputs must not leave stale success evidence.
  for log in harness build server client; do : >"$work_dir/$log.log"; done
  # Invalidate evidence even if Python is missing or metadata capture fails.
  rm -f "$work_dir/resources-summary.json" "$work_dir/resources-environment.json" \
    "$work_dir/resources-summary.tmp" "$work_dir/resources-environment.tmp"
  : >"$work_dir/resources.jsonl"
  local status=0 interrupted=0 runner_pid gnu_timeout
  python3 "$resource_observer" init --directory "$work_dir" --root "$project_root" || status=$?
  configure >>"$work_dir/harness.log" 2>&1 || status=$?
  if ((status == 0 && $# != 0)); then
    printf 'configure via STREAMING_SOAK_* environment variables, not arguments\n' >>"$work_dir/harness.log"
    status=2
  fi
  if ((status == 0)); then
    gnu_timeout=$(select_gnu_timeout 2>>"$work_dir/harness.log") || status=$?
  fi
  if ((status == 0)); then
    printf 'gnu_timeout=%s\n' "$gnu_timeout" >>"$work_dir/harness.log"
    printf 'Streaming soak running; logs: %s (overall timeout %ss)\n' "$work_dir" "$overall_timeout"
    # GNU timeout covers builds AND all children; retain any validation output.
    "$gnu_timeout" --signal=TERM --kill-after=5s "${overall_timeout}s" bash "${BASH_SOURCE[0]}" --run \
      >>"$work_dir/harness.log" 2>&1 &
    runner_pid=$!
    # Forward signals sent only to this wrapper PID to timeout's process group.
    # timeout owns TERM->KILL escalation even when a build or peer does not exit.
    trap 'interrupted=130; kill -TERM "$runner_pid" 2>/dev/null || true' INT
    trap 'interrupted=143; kill -TERM "$runner_pid" 2>/dev/null || true' TERM
    wait "$runner_pid" || status=$?
    if ((interrupted != 0)); then
      wait "$runner_pid" || true
      status=$interrupted
    fi
    trap - INT TERM
  fi
  # Missing/incomplete observation must never become a successful harness report.
  if ! python3 "$resource_observer" finalize --directory "$work_dir" --harness-exit "$status"; then
    if ((status == 0)); then status=1; fi
  fi
  cat "$work_dir/harness.log"
  printf 'harness_exit=%d\n' "$status" | tee -a "$work_dir/harness.log"
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
