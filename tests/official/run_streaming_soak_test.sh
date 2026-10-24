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

for pair in 010:10 08:8 0:0 000000000:0 000000008:8 999999999:999999999; do
  STREAMING_SOAK_SEED=${pair%:*} configure
  [[ "$seed" == "${pair#*:}" ]]
done

invalid_configurations=(
  STREAMING_SOAK_MODE=invalid
  STREAMING_SOAK_DURATION_SECONDS=0
  STREAMING_SOAK_DURATION_SECONDS=01
  STREAMING_SOAK_DURATION_SECONDS=-1
  STREAMING_SOAK_DURATION_SECONDS=1s
  STREAMING_SOAK_DURATION_SECONDS=999999
  STREAMING_SOAK_TIMEOUT_SECONDS=40
  STREAMING_SOAK_TIMEOUT_SECONDS=garbage
  STREAMING_SOAK_SEED=-1
  STREAMING_SOAK_SEED=1000000000
  STREAMING_SOAK_SEED=18446744073709551616
)
for assignment in "${invalid_configurations[@]}"; do
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
# Execute the real entrypoint in a temporary project layout. Invalid inputs must
# stop before any build, and must replace success artifacts from an earlier run.
fixture_root="$test_dir/project"
mkdir -p "$fixture_root/tests/official"
runner="$fixture_root/tests/official/run_streaming_soak.sh"
cp "$project_root/tests/official/run_streaming_soak.sh" "$runner"
fixture_logs="$fixture_root/.zig-cache/official/streaming-soak"
for previous in absent success; do
  for assignment in "${invalid_configurations[@]}"; do
    rm -rf "$fixture_logs"
    if [[ "$previous" == success ]]; then
      mkdir -p "$fixture_logs"
      for log in harness build server client; do
        printf 'PASS old success\nharness_exit=0\n' >"$fixture_logs/$log.log"
      done
    fi
    status=0
    env "$assignment" bash "$runner" >"$test_dir/output.log" 2>&1 || status=$?
    [[ "$status" == 2 ]]
    grep -q 'must' "$fixture_logs/harness.log"
    grep -qx 'harness_exit=2' "$fixture_logs/harness.log"
    if grep -qE 'PASS|harness_exit=0' "$fixture_logs/harness.log"; then
      printf 'stale success artifact for %s\n' "$assignment" >&2
      exit 1
    fi
    cmp "$test_dir/output.log" "$fixture_logs/harness.log"
    for log in build server client; do
      [[ -f "$fixture_logs/$log.log" && ! -s "$fixture_logs/$log.log" ]]
    done
  done
done

# Internal dispatch must not initialize/truncate artifacts a second time.
# Stub only the heavy workload; exercise main's real --run/configuration path.
for log in harness build server client; do
  printf 'outer invocation marker\n' >"$fixture_logs/$log.log"
done
STREAMING_SOAK_SEED=08 bash -c '
  source "$1"
  run_soak() { printf "internal-seed=%s\n" "$seed"; }
  main --run
' _ "$runner" >>"$fixture_logs/harness.log" 2>&1
for log in harness build server client; do
  grep -qx 'outer invocation marker' "$fixture_logs/$log.log"
done
grep -qx 'internal-seed=8' "$fixture_logs/harness.log"
# Save a compatible executable before shadowing PATH; it may be PATH-only.
selected_timeout=$(select_gnu_timeout)
# Anchor relative selections before reusing them as targets in another directory;
# do not dereference symlinks or split paths containing spaces.
if [[ "$selected_timeout" != /* ]]; then
  selected_timeout="$PWD/$selected_timeout"
fi
system_timeout=$(PATH='' select_gnu_timeout 2>/dev/null) || system_timeout=
# A mise-like incompatible timeout shadows PATH. Where system GNU is installed,
# exercise its precedence and the actual GNU options with a tiny child fixture
# that fails before builds. PATH-only hosts still run all fallback tests below.
shadow_dir="$test_dir/shadow"
mkdir -p "$shadow_dir"
cat >"$shadow_dir/timeout" <<'EOF'
#!/bin/bash
printf 'called\n' >>"$0.called"
printf 'timeout (incompatible fixture)\n'
exit 64
EOF
chmod +x "$shadow_dir/timeout"
if [[ -n "$system_timeout" ]]; then
  [[ $(PATH="$shadow_dir:$PATH" select_gnu_timeout) == "$system_timeout" ]]
  printf '#!/bin/bash\nexit 23\n' >"$fixture_root/tests/official/run_streaming_soak_test.sh"
  status=0
  PATH="$shadow_dir:$PATH" bash "$runner" >"$test_dir/output.log" 2>&1 || status=$?
  [[ "$status" == 23 && ! -e "$shadow_dir/timeout.called" ]]
  grep -qx "gnu_timeout=$system_timeout" "$fixture_logs/harness.log"
  grep -qx 'harness_exit=23' "$fixture_logs/harness.log"
fi

# A verified PATH installation is supported when no system candidate exists.
fallback_dir="$test_dir/fallback"
mkdir -p "$fallback_dir"
ln -s "$selected_timeout" "$fallback_dir/timeout"
(
  gnu_timeout_paths=()
  [[ $(PATH="$fallback_dir:$PATH" select_gnu_timeout) == "$fallback_dir/timeout" ]]
)

# Simulate missing system candidates locally; do not mutate host installations.
# An incompatible PATH command must produce fresh diagnostics/status, not launch
# the workload, with both absent artifacts and pre-existing success artifacts.
for previous in absent success; do
  rm -rf "$fixture_logs"
  if [[ "$previous" == success ]]; then
    mkdir -p "$fixture_logs"
    for log in harness build server client; do
      printf 'PASS old success\nharness_exit=0\n' >"$fixture_logs/$log.log"
    done
  fi
  status=0
  bash -c '
    source "$1"
    gnu_timeout_paths=()
    PATH="$2:$PATH"
    main
  ' _ "$runner" "$shadow_dir" >"$test_dir/output.log" 2>&1 || status=$?
  [[ "$status" == 2 ]]
  grep -q 'GNU coreutils timeout is required' "$fixture_logs/harness.log"
  grep -qx 'harness_exit=2' "$fixture_logs/harness.log"
  if grep -qE 'PASS|harness_exit=0' "$fixture_logs/harness.log"; then
    printf 'stale success artifact after GNU timeout selection failed\n' >&2
    exit 1
  fi
  cmp "$test_dir/output.log" "$fixture_logs/harness.log"
  for log in build server client; do
    [[ -f "$fixture_logs/$log.log" && ! -s "$fixture_logs/$log.log" ]]
  done
done
# Run this entire mandatory suite against an isolated PATH-only runner copy.
# Its empty system-candidate list also prevents recursively repeating this case.
if [[ -n "$system_timeout" ]]; then
  path_only_root="$test_dir/path-only-project"
  mkdir -p "$path_only_root/tests/official"
  sed 's|^gnu_timeout_paths=(/usr/bin/timeout /bin/timeout)$|gnu_timeout_paths=()|' \
    "$project_root/tests/official/run_streaming_soak.sh" >"$path_only_root/tests/official/run_streaming_soak.sh"
  grep -qx 'gnu_timeout_paths=()' "$path_only_root/tests/official/run_streaming_soak.sh"
  cp "$project_root/tests/official/run_streaming_soak_test.sh" "$path_only_root/tests/official/"
  PATH="$fallback_dir:$PATH" bash "$path_only_root/tests/official/run_streaming_soak_test.sh"
  printf '%s\n' 'PATH-only mandatory shell suite passed'
  # Exercise a relative PATH entry containing spaces and a valid symlink,
  # not just the absolute fallback path used by the preceding invocation.
  mkdir -p "$path_only_root/relative tools/bin"
  ln -s "$selected_timeout" "$path_only_root/relative tools/bin/timeout"
  (
    cd "$path_only_root"
    PATH="relative tools/bin:$PATH" bash tests/official/run_streaming_soak_test.sh
  )
  printf '%s\n' 'Relative PATH-only mandatory shell suite passed'
fi
printf '%s\n' 'streaming soak harness unit tests passed'
