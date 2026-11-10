#!/bin/bash
# Shared environment for macOS test scripts. Source it; do not execute it.
# Resolves the SDK once: an explicit FP_SDK_PATH wins, otherwise the active
# Xcode/CLT SDK. Never hardcode a versioned SDK path here.
if [[ -z "${FP_SDK_PATH:-}" ]]; then
    FP_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
export FP_SDK_PATH
