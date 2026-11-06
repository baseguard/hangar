#!/bin/bash
# The steps of the release workflow (.github/workflows/release.yaml) that take more than a line.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

USAGE="Usage: packaging/release.sh import-certificate | sign | notarize | remove-keys"
[[ $# -eq 1 ]] || fail "$USAGE"
[[ -n "${RUNNER_TEMP:-}" ]] || fail "packaging/release.sh runs in the release workflow, where RUNNER_TEMP is set."
cd "$ROOT"

APP="$DIST/Hangar.app"
CLI="$APP/Contents/Helpers/HangarCLI.app"
DMG="$DIST/Hangar.dmg"
KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"

# The certificate goes into a keychain of its own, unlocked for the run, that only codesign may use.
import_certificate() {
    local certificate="$RUNNER_TEMP/certificate.p12"
    local password
    password="$(uuidgen)"
    (umask 077 && printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$certificate")

    security create-keychain -p "$password" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$password" "$KEYCHAIN"
    security import "$certificate" -k "$KEYCHAIN" -f pkcs12 -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN" > /dev/null
    rm -f "$certificate"

    security list-keychains -d user | xargs security list-keychains -d user -s "$KEYCHAIN"
}

# The command line is an app of its own, so it carries the profile its Keychain access group needs. Signed inside
# out: the command line first, then the app around it.
sign_with_profiles() {
    embed_profile "$CLI_PROVISIONING_PROFILE" "$CLI"
    embed_profile "$PROVISIONING_PROFILE" "$APP"

    local cli_entitlements app_entitlements
    cli_entitlements="$(entitlements_for Resources/Hangar.entitlements io.baseguard.hangar.cli)"
    app_entitlements="$(entitlements_for Resources/HangarApp.entitlements io.baseguard.hangar)"

    codesign --force --options runtime --timestamp --entitlements "$cli_entitlements" --sign "$SIGN_IDENTITY" "$CLI"
    codesign --force --options runtime --timestamp --entitlements "$app_entitlements" --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
}

# Writes the base64 profile into the bundle and checks that it is ours.
embed_profile() {
    local encoded="$1" bundle="$2"
    local profile="$bundle/Contents/embedded.provisionprofile"
    printf '%s' "$encoded" | base64 --decode > "$profile"

    local team
    team="$(security cms -D -i "$profile" | plutil -extract TeamIdentifier.0 raw -o - -)"
    [[ "$team" == "$TEAM_ID" ]] || fail "$profile isn't for team $TEAM_ID."
}

# A copy of the entitlements with the application and team identifiers a provisioning profile requires.
entitlements_for() {
    local source="$1" bundle_id="$2"
    local copy="$RUNNER_TEMP/$(basename "$source")"
    cp "$source" "$copy"
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.application-identifier string $TEAM_ID.$bundle_id" \
        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
        "$copy"
    echo "$copy"
}

sign_and_notarize_dmg() {
    codesign --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"

    local key="$RUNNER_TEMP/AuthKey_$API_KEY_ID.p8"
    (umask 077 && printf '%s\n' "$API_KEY_P8" > "$key")
    xcrun notarytool submit "$DMG" --key "$key" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" --wait
    rm -f "$key"

    xcrun stapler staple "$DMG"
}

remove_keys() {
    security delete-keychain "$KEYCHAIN" || true
    rm -f "$RUNNER_TEMP/certificate.p12" "$RUNNER_TEMP"/AuthKey_*.p8
}

case "${1:-}" in
    import-certificate) import_certificate ;;
    sign) sign_with_profiles ;;
    notarize) sign_and_notarize_dmg ;;
    remove-keys) remove_keys ;;
    *) fail "$USAGE" ;;
esac
