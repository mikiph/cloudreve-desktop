#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/macos/scripts/test-env.sh"
TEST_BINARY="${TMPDIR:-/tmp}/cloudreve-pending-policy-tests"
export CLANG_MODULE_CACHE_PATH="$ROOT/macos/build/TestModuleCache"
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "${FP_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -framework Foundation -framework AppKit -framework FileProvider -framework UniformTypeIdentifiers \
    -o "$TEST_BINARY" "$ROOT/macos/fileprovider/Sources/"*.swift \
    "$ROOT/macos/fileprovider/Tests/PendingPolicyUpdateTests.swift"
"$TEST_BINARY"
