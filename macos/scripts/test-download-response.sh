#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/macos/scripts/test-env.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudreve-download-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -sdk "$FP_SDK_PATH" \
    -module-cache-path "$ROOT/macos/build/TestModuleCache" \
    -framework Foundation -framework AppKit -framework FileProvider -framework UniformTypeIdentifiers \
    -o "$TEST_DIR/tests" "$ROOT/macos/fileprovider/Sources/"*.swift \
    "$ROOT/macos/fileprovider/Tests/DownloadResponseTests.swift"
"$TEST_DIR/tests"
