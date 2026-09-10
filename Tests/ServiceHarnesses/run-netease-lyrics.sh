#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_dir"
output_dir="$repo_dir/build/validation/lyrics-271"
mkdir -p "$output_dir/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    -module-cache-path "$output_dir/module-cache" \
    Tests/ServiceHarnesses/NetEaseLyricsClientHarness.swift \
    Tests/ServiceHarnesses/OriginalLyricsProviderHarness.swift \
    boringNotch/Interaction/Core/LyricsCore.swift \
    boringNotch/Interaction/Core/OriginalLyricsCore.swift \
    boringNotch/Interaction/NetEaseLyricsClient.swift \
    boringNotch/Interaction/OriginalLyricsProvider.swift \
    -o "$output_dir/netease-lyrics-client-harness"
"$output_dir/netease-lyrics-client-harness" > "$output_dir/netease-client-tests.log"
cat "$output_dir/netease-client-tests.log"
