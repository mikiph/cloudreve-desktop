#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/macos/scripts/test-env.sh"
TEST_BINARY="${TMPDIR:-/tmp}/cloudreve-journal-event-type-tests"
export CLANG_MODULE_CACHE_PATH="$ROOT/macos/build/TestModuleCache"
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "$FP_SDK_PATH" -framework Foundation \
    -o "$TEST_BINARY" "$ROOT/macos/fileprovider/Sources/JournalEventType.swift" \
    "$ROOT/macos/fileprovider/Tests/JournalEventTypeTests.swift"
"$TEST_BINARY" "$ROOT/macos/fileprovider/Tests/Fixtures/journal-event-types.txt"
