#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib.sh"

APP="${APP:-$DIST/Hangar.app}"
DMG="${DMG:-$DIST/Hangar.dmg}"
WINDOW="$ROOT/packaging/dmg/DMGWindow.swift"
MOUNT=""

app_version() {
    /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo dev
}

cleanup() {
    if [[ -n "$MOUNT" ]]; then
        hdiutil detach "$MOUNT" -force -quiet || true
    fi
    rm -rf "$WORK"
}

# The mount point from the attach output's partition line: "/dev/disk4s1<tab>Apple_HFS<tab>/Volumes/Hangar 1.0.0".
mount_point() {
    awk -F '\t' '/Apple_HFS/ { print $NF }'
}

stage_contents() {
    mkdir -p "$WORK/stage/.background" "$WORK/art"
    ditto "$APP" "$WORK/stage/Hangar.app"
    ln -s /Applications "$WORK/stage/Applications"
    swift "$WINDOW" background "$WORK/art"
    tiffutil -cathidpicheck "$WORK/art/background.png" "$WORK/art/background@2x.png" \
        -out "$WORK/stage/.background/background.tiff" 2>/dev/null
    cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/stage/.VolumeIcon.icns"
}

create_image() {
    hdiutil create -volname "Hangar $(app_version)" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -quiet "$WORK/rw.dmg"
}

lay_out_window() {
    MOUNT="$(diskutil image attach --nobrowse "$WORK/rw.dmg" | mount_point)"
    [[ -n "$MOUNT" ]] || fail "Could not mount $WORK/rw.dmg"
    swift "$WINDOW" layout "$MOUNT" Hangar.app
    xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
    rm -rf "$MOUNT/.fseventsd"
    hdiutil detach "$MOUNT" -quiet
    MOUNT=""
}

compress() {
    mkdir -p "$(dirname "$DMG")"
    rm -f "$DMG"
    hdiutil convert "$WORK/rw.dmg" -format ULFO -quiet -o "$DMG"
    echo "Built $DMG"
}

[[ -d "$APP" ]] || fail "$APP not found; run make build first."
WORK="$(mktemp -d)"
trap cleanup EXIT

stage_contents
create_image
lay_out_window
compress
