#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloudreve-file-info-prefetch.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_BINARY="$TEST_ROOT/file-info-prefetch-tests"
SOURCE_ROOT="${FP_TEST_SOURCE_DIR:-$ROOT/macos/fileprovider/Sources}"
mkdir "$TEST_ROOT/Sources"
cp "$SOURCE_ROOT/"*.swift "$TEST_ROOT/Sources/"
cp "$ROOT/macos/fileprovider/Tests/FileInfoPrefetchTests.swift" "$TEST_ROOT/FileInfoPrefetchTests.swift"
export CLANG_MODULE_CACHE_PATH="$ROOT/macos/build/TestModuleCache"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "${FP_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -framework Foundation -framework AppKit -framework FileProvider -framework UniformTypeIdentifiers \
    -o "$TEST_BINARY" "$TEST_ROOT/Sources/"*.swift \
    "$TEST_ROOT/FileInfoPrefetchTests.swift"
"$TEST_BINARY" "$@"
