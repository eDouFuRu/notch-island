#!/bin/bash
set -euo pipefail
# This harness injects a fake device. It never runs CoreGraphics display reads/writes.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d /tmp/notch-display-mode-tests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
swiftc -swift-version 5 -module-cache-path "$test_root/module-cache" \
    "$repo_root/boringNotch/Interaction/Core/DisplayModeSelection.swift" \
    "$repo_root/boringNotch/Interaction/SystemDisplayModeControl.swift" \
    "$repo_root/Tests/ServiceHarnesses/DisplayModeControlHarness.swift" \
    -o "$test_root/harness"
"$test_root/harness"
