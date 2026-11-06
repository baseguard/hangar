#!/bin/bash
# Builds the traffic libraries in Release and times TrafficInspector per frame (Tests/Benchmarks/TrafficInspector).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

BENCH="$ROOT/.build/bench"
PRODUCTS="$BENCH/sym/Release"

xcodebuild -project "$ROOT/Hangar.xcodeproj" -target HangarTraffic -configuration Release CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO SYMROOT="$BENCH/sym" OBJROOT="$BENCH/obj" -quiet build
xcrun swiftc -O -package-name Hangar -target arm64-apple-macos27.0 -I "$PRODUCTS" -L "$PRODUCTS" \
    -lHangarTraffic -lHangarPackets -lHangarSupport "$ROOT/Tests/Benchmarks/TrafficInspector/main.swift" \
    -o "$BENCH/traffic"
"$BENCH/traffic"
