#!/bin/bash
source "$(dirname "$0")/environment.sh"
cleaner_prepare_engine
swift build --sdk "$cleaner_sdk" -c release
cleaner_bin=$(swift build --sdk "$cleaner_sdk" -c release --show-bin-path)
cleaner_app="$PWD/build/TidyMac.app"
mkdir -p "$cleaner_app/Contents/MacOS" "$cleaner_app/Contents/Resources" "$cleaner_app/Contents/Library/HelperTools" "$cleaner_app/Contents/Library/LaunchDaemons"
cp "$cleaner_bin/CleanerHelper" "$cleaner_app/Contents/Library/HelperTools/"
cp resources/local.cleanmymac.CleanMyMacLocal.helper.plist "$cleaner_app/Contents/Library/LaunchDaemons/"
cp "$cleaner_bin/TidyMac" "$cleaner_app/Contents/MacOS/"
# Swift Build resolves Bundle.module from the app resource directory.
for cleaner_bundle in "$cleaner_bin"/*.bundle; do
    [[ -d "$cleaner_bundle" ]] || continue
    ditto "$cleaner_bundle" "$cleaner_app/Contents/Resources/$(basename "$cleaner_bundle")"
done
cp resources/Info.plist "$cleaner_app/Contents/Info.plist"
cleaner_identity="${CLEANER_SIGN_IDENTITY:--}"
codesign --force --options runtime --identifier local.cleanmymac.CleanMyMacLocal.helper --sign "$cleaner_identity" "$cleaner_app/Contents/Library/HelperTools/CleanerHelper"
codesign --force --options runtime --sign "$cleaner_identity" "$cleaner_app"
codesign --verify --strict "$cleaner_app/Contents/Library/HelperTools/CleanerHelper"
codesign --verify --strict "$cleaner_app"
printf '%s\n' "$cleaner_app"
