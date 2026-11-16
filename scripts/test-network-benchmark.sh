#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .cache/clang .cache/swiftpm
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="$PWD/.cache/swiftpm"
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

SCRATCH="/private/tmp/drivegauge-network-self-tests"
swift build --disable-sandbox --scratch-path "$SCRATCH" --product DriveGaugeNetworkWorker
swift build --disable-sandbox --scratch-path "$SCRATCH" --product NetworkBenchmarkSelfTests
"$SCRATCH/debug/NetworkBenchmarkSelfTests"

BIN_PATH="$(swift build --disable-sandbox --scratch-path "$SCRATCH" --show-bin-path)"
swiftc -parse-as-library \
    -I "$BIN_PATH" \
    Sources/DriveGauge/NetworkBenchmarkEngine.swift \
    Tests/NetworkBenchmarkEngineTests/TestSupport.swift \
    Tests/NetworkBenchmarkEngineTests/main.swift \
    "$BIN_PATH/NetworkBenchmarkProtocol.o" \
    -o "$SCRATCH/NetworkBenchmarkEngineIntegrationTests"
"$SCRATCH/NetworkBenchmarkEngineIntegrationTests" "$SCRATCH/debug/DriveGaugeNetworkWorker"

swiftc -parse-as-library \
    Sources/DriveGauge/BenchmarkEngine.swift \
    Tests/LocalBenchmarkSmoke/main.swift \
    -o "$SCRATCH/LocalBenchmarkSmoke"
"$SCRATCH/LocalBenchmarkSmoke"
