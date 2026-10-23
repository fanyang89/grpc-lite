#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -x "$1" ]]; then
    echo "usage: $0 /path/to/grpc-lite-streaming-lifecycle" >&2
    exit 2
fi
executable=$1
# PATH's timeout may be zigcli, which does not enforce this watchdog contract.
watchdog=/usr/bin/timeout
if [[ ! -x "$watchdog" ]] || ! "$watchdog" --version | grep -Fq 'GNU coreutils'; then
    echo 'GNU /usr/bin/timeout is required' >&2
    exit 2
fi

output=$(mktemp)
trap 'rm -f "$output"' EXIT
for mode in normal interrupt; do
    if "$watchdog" --signal=TERM --kill-after=2s 20s "$executable" "$mode" >"$output" 2>&1; then
        cat "$output"
    else
        status=$?
        cat "$output" >&2
        echo "streaming lifecycle $mode failed (exit $status; watchdog expiry is a failure)" >&2
        exit "$status"
    fi
    expected_status=ok
    if [[ "$mode" == interrupt ]]; then expected_status=cancelled; fi
    expected="PASS streaming-lifecycle mode=$mode status=$expected_status backpressure=1 writable=1 half_close=1 messages=2 client_terminal=1 server_terminal=1 released=1 drained=1"
    if [[ $(grep -Fxc "$expected" "$output" || true) != 1 ]]; then
        echo "streaming lifecycle $mode did not satisfy the lifecycle contract" >&2
        exit 1
    fi
done
