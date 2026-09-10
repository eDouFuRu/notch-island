#!/bin/bash
set -euo pipefail

ISLAND_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISLAND_TEST_BUILD="$(mktemp -d /tmp/notch-services.XXXXXX)"
trap 'rm -rf "$ISLAND_TEST_BUILD"' EXIT

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Service harnesses require macOS 15+ and the Xcode command-line tools." >&2
    exit 1
fi

python3 "$ISLAND_TEST_ROOT/Tests/ServiceHarnesses/assemble.py" "$ISLAND_TEST_BUILD"

ISLAND_TEST_NAMES=(HUDStateHarness CalendarManagerHarness CalendarServiceHarness CalendarScrollHarness BatteryNotificationHarness QuickShareLifecycleHarness HardwareControlsHarness ShelfChordHarness)
ISLAND_TEST_EXPECTED=(30 11 4 7 8 7 22 8)
ISLAND_TEST_TOTAL=0

for ISLAND_TEST_INDEX in "${!ISLAND_TEST_NAMES[@]}"; do
    ISLAND_TEST_NAME="${ISLAND_TEST_NAMES[$ISLAND_TEST_INDEX]}"
    xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
        -Onone -module-cache-path "$ISLAND_TEST_BUILD/ModuleCache" -parse-as-library \
        "$ISLAND_TEST_BUILD/$ISLAND_TEST_NAME.swift" -o "$ISLAND_TEST_BUILD/$ISLAND_TEST_NAME"
    ISLAND_TEST_OUTPUT="$("$ISLAND_TEST_BUILD/$ISLAND_TEST_NAME")"
    printf '%s\n' "$ISLAND_TEST_OUTPUT"
    ISLAND_TEST_COUNT="$(printf '%s\n' "$ISLAND_TEST_OUTPUT" | sed -nE 's/^.*checks: ([0-9]+) passed.*$/\1/p')"
    if [[ "$ISLAND_TEST_COUNT" != "${ISLAND_TEST_EXPECTED[$ISLAND_TEST_INDEX]}" ]]; then
        echo "Unexpected check count for $ISLAND_TEST_NAME: $ISLAND_TEST_COUNT" >&2
        exit 1
    fi
    ISLAND_TEST_TOTAL=$((ISLAND_TEST_TOTAL + ISLAND_TEST_COUNT))
done

[[ "$ISLAND_TEST_TOTAL" == 97 ]]
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "$ISLAND_TEST_BUILD/ModuleCache" -typecheck \
    "$ISLAND_TEST_BUILD/MediaKeyInterceptorTypecheck.swift"
printf 'Production media-key event-tap adapter: typecheck passed (no tap installed)\n'
printf 'Service regression checks: %s passed (8 groups: 30 + 11 + 4 + 7 + 8 + 7 + 22 + 8)\n' "$ISLAND_TEST_TOTAL"
