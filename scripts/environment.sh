#!/bin/bash
# Sourced by the build/test scripts; never changes the user's shell configuration.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export MACOSX_DEPLOYMENT_TARGET=26.0
if [[ -n "${CLEANER_SDK:-}" ]]; then
    cleaner_sdk="$CLEANER_SDK"
elif cleaner_sdk=$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null); then
    :
else
    cleaner_sdk=$(xcrun --sdk macosx --show-sdk-path)
fi

# SwiftPM does not consistently track an external library passed with -l.
# Invalidate Swift products only when the actual Rust library content changes.
cleaner_prepare_engine() {
    cargo build --manifest-path engine/Cargo.toml --release --locked
    local cleaner_digest
    cleaner_digest=$(shasum -a 256 engine/target/release/libcleaner_engine.a | cut -d ' ' -f 1)
    if [[ "$cleaner_digest" != "$(cat .build/cleaner-engine.hash 2>/dev/null || true)" ]]; then
        swift package clean
        mkdir -p .build
        printf '%s\n' "$cleaner_digest" > .build/cleaner-engine.hash
    fi
}
