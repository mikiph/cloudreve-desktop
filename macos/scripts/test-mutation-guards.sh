#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/cloudreve-mutation-guards-tests"
export CLANG_MODULE_CACHE_PATH="$ROOT/macos/build/TestModuleCache"
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "${FP_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -framework Foundation -framework AppKit -framework FileProvider -framework UniformTypeIdentifiers \
    -o "$TEST_BINARY" "$ROOT/macos/fileprovider/Sources/"*.swift \
    "$ROOT/macos/fileprovider/Tests/MutationGuardsTests.swift"
"$TEST_BINARY"
