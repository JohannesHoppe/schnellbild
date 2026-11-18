#!/bin/bash
# Runs the SwiftPM unit tests. VLCKit is a binary framework linked into the
# module, but SwiftPM doesn't embed it into the .xctest bundle — and its
# install name is @loader_path/../Frameworks/… — so we copy it in before
# running, then test without rebuilding.
#
# Arguments go to `swift test` (`--filter VideoFormatTests`). REPEAT=<n>
# runs them n times, stopping at the first failure.
#
# The tests run under a pseudo-terminal (`script`), so each line of their
# output reaches the log as it is written, not in blocks: a test that hangs
# is the last one "started". A run longer than UNIT_TEST_TIMEOUT seconds
# (default 1200) is taken for a hang: the test process's threads are
# sampled into the log (`sample`, macOS's own), then it is ended.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/fetch_vlckit.sh

swift build --build-tests
BIN="$(swift build --show-bin-path)"
XCTEST="$BIN/SchnellbildPackageTests.xctest"
mkdir -p "$XCTEST/Contents/Frameworks"
ditto "$BIN/VLCKit.framework" "$XCTEST/Contents/Frameworks/VLCKit.framework"

timeout="${UNIT_TEST_TIMEOUT:-1200}"
repeat="${REPEAT:-1}"

# One run of the tests; its status, or 124 after the timeout
run_tests() {
    script -q /dev/null swift test --skip-build "$@" < /dev/null &
    local tests=$!
    (
        sleep "$timeout"
        echo "!! the unit tests ran longer than $timeout s: the test that started last hangs" >&2
        for pid in $(pgrep -f "SchnellbildPackageTests.xctest" || true); do
            echo "== threads of process $pid" >&2
            sample "$pid" 5 -mayDie >&2 2>&1 || true
        done
        touch "$BIN/.unit-tests-timed-out"
        pkill -f "SchnellbildPackageTests.xctest" || true
        kill "$tests" 2>/dev/null || true
    ) &
    local watchdog=$!
    local status=0
    wait "$tests" || status=$?
    # The watchdog and its sleep
    pkill -P "$watchdog" 2>/dev/null || true
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    if [ -e "$BIN/.unit-tests-timed-out" ]; then
        rm -f "$BIN/.unit-tests-timed-out"
        return 124
    fi
    return "$status"
}

rm -f "$BIN/.unit-tests-timed-out"
for run in $(seq 1 "$repeat"); do
    [ "$repeat" -gt 1 ] && echo "=== run $run of $repeat"
    run_tests "$@"
done
