#!/bin/bash
set -euo pipefail

# All subprocesses launched by this test are compiled from the fake C fixture.
# No native Bluetooth reads/writes, app launches or permission requests occur.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d /tmp/notch-bluetooth-tests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

clang "$repo_root/Tests/ServiceHarnesses/BluetoothPowerFakeHelper.c" -o "$test_root/fake"
for variant in bad exit hang; do cp "$test_root/fake" "$test_root/$variant"; done
swiftc -swift-version 5 -module-cache-path "$test_root/module-cache" \
    "$repo_root/boringNotch/Interaction/Core/BluetoothPowerTransaction.swift" \
    "$repo_root/boringNotch/Interaction/SystemBluetoothControl.swift" \
    "$repo_root/Tests/ServiceHarnesses/BluetoothPowerControlHarness.swift" \
    -o "$test_root/harness"
"$test_root/harness" "$test_root"
