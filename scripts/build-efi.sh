#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SOURCES="$ROOT/firmware"
OUTPUT="$ROOT/Sources/HangarKit/Installers/WindowsFirmware.swift"
LLD_LINK="$(command -v lld-link || echo /opt/homebrew/opt/lld/bin/lld-link)"

build_efi() {
    local name="$1" subsystem="$2"
    clang -target aarch64-unknown-windows -ffreestanding -fno-builtin -fno-stack-protector -fshort-wchar \
        -mno-implicit-float -O2 -Wall -Wextra -Wno-unused-parameter -Werror \
        -c "$SOURCES/$name.c" -o "$BUILD/$name.o"
    "$LLD_LINK" /nologo /Brepro /nodefaultlib /dll /entry:efi_main "/subsystem:$subsystem" \
        "/out:$BUILD/$name.efi" "$BUILD/$name.o"
}

write_swift_source() {
    cat > "$OUTPUT" <<EOF
import Foundation

enum WindowsFirmware {
    static let framebufferDriver = decode(
        "$(base64 -i "$BUILD/hangarfb.efi")"
    )

    static let bootstrap = decode(
        "$(base64 -i "$BUILD/bootstrap.efi")"
    )

    private static func decode(_ base64: String) -> Data {
        guard let data = Data(base64Encoded: base64) else {
            preconditionFailure("WindowsFirmware holds invalid base64; run make efi.")
        }
        return data
    }
}
EOF
}

[[ -x "$LLD_LINK" ]] || fail "lld-link not found. Install it with: brew install lld"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

build_efi hangarfb efi_boot_service_driver
build_efi bootstrap efi_application
write_swift_source
ls -l "$BUILD"/*.efi | awk '{print $5, $NF}'
echo "Wrote $OUTPUT"
