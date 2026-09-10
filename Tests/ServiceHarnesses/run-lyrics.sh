#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_dir"
output_dir="$repo_dir/build/validation/brief-lyrics"
products_dir="$repo_dir/build/Build/Products/Debug"
mkdir -p "$output_dir/module-cache"
if [[ ! -f "$products_dir/Defaults.o" ]]; then
    echo "Missing compiled Defaults dependency in $products_dir; build the Debug project before running this harness." >&2
    exit 1
fi
CLANG_MODULE_CACHE_PATH="$output_dir/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$output_dir/module-cache" \
    swift test --disable-sandbox --filter LyricsTests > "$output_dir/lyrics-core-tests.log" 2>&1
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    -module-cache-path "$output_dir/module-cache" -I "$products_dir" \
    Tests/ServiceHarnesses/LyricsStoreHarness.swift \
    boringNotch/models/PlaybackState.swift boringNotch/Interaction/Core/LyricsCore.swift \
    boringNotch/Interaction/Core/OriginalLyricsCore.swift \
    boringNotch/Interaction/OriginalLyricsProvider.swift boringNotch/Interaction/NetEaseLyricsClient.swift \
    boringNotch/Interaction/LyricsStore.swift "$products_dir/Defaults.o" \
    -o "$output_dir/lyrics-service-harness"
"$output_dir/lyrics-service-harness" > "$output_dir/lyrics-service-tests.log"
cat "$output_dir/lyrics-service-tests.log"
echo "Core log: $output_dir/lyrics-core-tests.log"
