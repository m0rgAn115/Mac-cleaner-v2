#!/bin/bash
source "$(dirname "$0")/environment.sh"
cargo fmt --manifest-path engine/Cargo.toml --check
cargo test --manifest-path engine/Cargo.toml --locked
cleaner_prepare_engine
cleaner_swift=$(xcrun --find swift)
cleaner_testing_plugin="$(dirname "$cleaner_swift")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
cleaner_test_flags=()
if [[ -f "$cleaner_testing_plugin" ]]; then
    cleaner_test_flags=(-Xswiftc -load-plugin-library -Xswiftc "$cleaner_testing_plugin")
fi
swift test --sdk "$cleaner_sdk" "${cleaner_test_flags[@]}"
