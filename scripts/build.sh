#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP="$DIST/Hangar.app"
DERIVED="$ROOT/.build/xcode"
VERSION="${VERSION:-0.0.0}"
IDENTITY="${SIGN_IDENTITY:--}"

use_xcode() {
    if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" != *Xcode* && -d /Applications/Xcode.app ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
}

# The Keychain access group needs a provisioning profile: an ad hoc signature can't have one, and Xcode refuses to sign
# with it without one. So the build goes without the group and keeps its secrets in the login keychain; the release
# workflow signs the app and its command line again with their profiles and the group.
signing_settings() {
    # Absolute, because the setting also reaches the package targets, which resolve a relative path in their own folder.
    local entitlements="$ROOT/Resources/HangarUnprovisioned.entitlements"
    SIGNING=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        "CODE_SIGN_ENTITLEMENTS=$entitlements" "CODE_SIGN_IDENTITY=$IDENTITY")
    if [[ "$IDENTITY" != "-" ]]; then
        SIGNING+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
    else
        # The hardened runtime loads only libraries of the app's own team, and an ad hoc signature has none, so the
        # app couldn't load HangarKit.framework; it matters only for notarizing, which needs a Developer ID anyway.
        SIGNING+=(ENABLE_HARDENED_RUNTIME=NO)
    fi
}

# A plain build keeps every symbol, about half of each binary; DEPLOYMENT_POSTPROCESSING strips them as an archive does.
# The C in the Swift packages (BoringSSL) names its source files in its errors; mapped, they don't carry the build
# machine's checkout path. Set here, the flag reaches the package targets too.
build_release() {
    xcodebuild -project Hangar.xcodeproj -scheme Hangar -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED" -onlyUsePackageVersionsFromResolvedFile -quiet DEPLOYMENT_POSTPROCESSING=YES \
        "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=/hangar -ffile-prefix-map=$HOME=/home" \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" "${SIGNING[@]}" build
}

copy_to_dist() {
    rm -rf "$APP"
    mkdir -p "$DIST"
    ditto "$DERIVED/Build/Products/Release/Hangar.app" "$APP"
    echo "Built $APP ($VERSION)"
}

# The signing settings above give every target Hangar.entitlements; the Share extension only loads sandboxed, so it
# gets its own entitlements, and the app is signed again around it with the entitlements it already has.
sign_share_extension() {
    local flags=(--force)
    if [[ "$IDENTITY" != "-" ]]; then
        flags+=(--options runtime --timestamp)
    fi
    codesign "${flags[@]}" --entitlements "$ROOT/Resources/HangarShare.entitlements" --sign "$IDENTITY" \
        "$APP/Contents/PlugIns/HangarShare.appex"
    codesign "${flags[@]}" --preserve-metadata=entitlements --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
}

cd "$ROOT"
use_xcode
signing_settings
build_release
copy_to_dist
sign_share_extension
