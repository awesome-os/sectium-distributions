#!/bin/sh
# Sectium / Awesome-OS Zero-Gatekeeper POSIX Installer
# One-liner: curl -fsSL https://awesome-os.com/install.sh | sh
# Supports Linux (x86_64/arm64) and macOS (Apple Silicon auto ad-hoc codesigned).
set -eu

PLANE_VERSION="0.2.0"
ABI_MAGIC="0x33564742"
ABI_VERSION="3"
INSTALL_DIR="${HOME}/.sectium/bin"
CHANNEL="rolling"
DRY_RUN=0
FROM_SOURCE=0
MANIFEST_URL="https://awesome-os.com/release-manifest.json"

usage() {
    cat <<'EOF'
Sectium / Awesome-OS Zero-Gatekeeper Installer
Usage: install.sh [--dry-run] [--dir <path>] [--channel rolling|stable] [--from-source]

Options:
  --dry-run             Print planned actions without writing files or making network calls
  --dir <path>          Installation directory (default: $HOME/.sectium/bin)
  --channel <name>      Release channel: rolling | stable (default: rolling)
  --from-source         Compile native C11 binaries locally via zig cc (< 1 s)
  -h, --help            Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --dir)
            if [ "$#" -lt 2 ]; then
                printf '[ERROR] --dir requires a path argument\n' >&2
                exit 1
            fi
            INSTALL_DIR="$2"
            shift 2
            ;;
        --channel)
            if [ "$#" -lt 2 ]; then
                printf '[ERROR] --channel requires rolling or stable\n' >&2
                exit 1
            fi
            CHANNEL="$2"
            shift 2
            ;;
        --from-source)
            FROM_SOURCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '[ERROR] Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$CHANNEL" in
    rolling|stable) ;;
    *)
        printf '[ERROR] Unsupported channel "%s" (expected rolling or stable)\n' "$CHANNEL" >&2
        exit 1
        ;;
esac

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
BASE_URL="https://awesome-os.com/releases/${CHANNEL}"

# Embedded rolling SHA-256 digests matching release-manifest.json
SHA256_SECTIUM_ES="2a01789e64917cc3e61ecd8500992834cd1bd17d2b708c88a5852c45ee31f1bb"
SHA256_SECTIUM_JVM="22f5d693963653f4c4a9d38515a8b53b84ad06376384396d39b729749688dbd1"
SHA256_SECTIUM_JVM_WASM="761002d39ac3f63b8f03399f43a634e13e58849f25d5835d0463cf310ce0dcc2"
SHA256_LIBSECTIUM_CP="ac493086199d7bac18a6cadc8a0b0a41f8e966f25fba17702f7490a92f578269"
SHA256_SECTIUM_CP_WASM="5d37c0ad32653ffe9a221ff35b80f4962754487724239bc7be97a4c55d65a5f0"

compute_sha256() {
    file_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print $1}'
    else
        printf '[ERROR] Neither sha256sum nor shasum is available for SHA-256 verification\n' >&2
        exit 1
    fi
}

verify_sha256() {
    file_path="$1"
    expected="$2"
    actual="$(compute_sha256 "$file_path")"
    if [ "$actual" != "$expected" ]; then
        rm -f "$file_path"
        printf '[ERROR] SHA-256 mismatch for %s (expected %s, got %s)\n' "$file_path" "$expected" "$actual" >&2
        exit 1
    fi
    printf '[OK] %s verified (sha256=%.16s...)\n' "$(basename "$file_path")" "$actual"
}

strip_quarantine_and_sign() {
    bin_path="$1"
    if [ "$OS_NAME" = "Darwin" ]; then
        if command -v xattr >/dev/null 2>&1; then
            xattr -d com.apple.quarantine "$bin_path" 2>/dev/null || true
        fi
        case "$ARCH_NAME" in
            arm64|aarch64)
                if command -v codesign >/dev/null 2>&1; then
                    codesign --force --sign - "$bin_path" >/dev/null 2>&1 || true
                    printf '[MACOS] Ad-hoc signed %s for Apple Silicon (%s)\n' "$(basename "$bin_path")" "$ARCH_NAME"
                fi
                ;;
        esac
    fi
}

build_from_source_zig() {
    src_root="$1"
    if ! command -v zig >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -f "${src_root}/sections/b8g-es/b8g_es_main.c" ] || \
       [ ! -f "${src_root}/sections/b8g-jvm/b8g_jvm_main.c" ] || \
       [ ! -f "${src_root}/sections/sectium-cloud-control-plane/sectium_cp.c" ]; then
        return 1
    fi

    printf '[ZIG] Compiling native C11 binaries via zig cc (< 1 s)...\n'
    zig cc -std=c11 -O2 -s \
        "${src_root}/sections/b8g-es/b8g_es_main.c" \
        "${src_root}/sections/b8g-es/b8g_es_vm.c" \
        -o "${INSTALL_DIR}/sectium-es"

    zig cc -std=c11 -O2 -s \
        "${src_root}/sections/b8g-jvm/b8g_jvm_main.c" \
        "${src_root}/sections/b8g-jvm/b8g_jvm_interp.c" \
        "${src_root}/sections/b8g-jvm/b8g_jvm_aot.c" \
        -o "${INSTALL_DIR}/sectium-jvm"

    if [ "$OS_NAME" = "Darwin" ]; then
        zig cc -std=c11 -O2 -s -shared \
            "${src_root}/sections/sectium-cloud-control-plane/sectium_cp.c" \
            -o "${INSTALL_DIR}/libsectium_cp.dylib"
        strip_quarantine_and_sign "${INSTALL_DIR}/libsectium_cp.dylib"
    else
        zig cc -std=c11 -O2 -s -shared -fPIC \
            "${src_root}/sections/sectium-cloud-control-plane/sectium_cp.c" \
            -o "${INSTALL_DIR}/libsectium_cp.so"
    fi

    chmod +x "${INSTALL_DIR}/sectium-es" "${INSTALL_DIR}/sectium-jvm"
    strip_quarantine_and_sign "${INSTALL_DIR}/sectium-es"
    strip_quarantine_and_sign "${INSTALL_DIR}/sectium-jvm"
    printf '[ZIG] Native C11 build complete (zero Gatekeeper quarantine)\n'
    return 0
}

fetch_and_verify() {
    name="$1"
    expected_sha="$2"
    make_exec="$3"
    dest="${INSTALL_DIR}/${name}"
    url="${BASE_URL}/${name}"

    if ! command -v curl >/dev/null 2>&1; then
        printf '[ERROR] curl is required to download %s\n' "$url" >&2
        exit 1
    fi

    curl -fsSL "$url" -o "$dest"
    verify_sha256 "$dest" "$expected_sha"
    if [ "$make_exec" = "1" ]; then
        chmod +x "$dest"
        strip_quarantine_and_sign "$dest"
    fi
}

ensure_path_entry() {
    export_line="export PATH=\"${INSTALL_DIR}:\$PATH\""
    for rc in "${HOME}/.profile" "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if [ -f "$rc" ]; then
            if ! grep -Fq "$INSTALL_DIR" "$rc" 2>/dev/null; then
                printf '\n# Sectium / Awesome-OS\n%s\n' "$export_line" >> "$rc"
                printf '[PATH] Added %s to %s\n' "$INSTALL_DIR" "$rc"
            fi
        fi
    done
}

printf '[SECTIUM] Awesome-OS / Sectium Installer v%s (channel=%s, abi=%s/v%s)\n' \
    "$PLANE_VERSION" "$CHANNEL" "$ABI_MAGIC" "$ABI_VERSION"
printf '[TARGET]  Host: %s/%s -> Install directory: %s\n' "$OS_NAME" "$ARCH_NAME" "$INSTALL_DIR"
printf '[SECURITY] Zero-Gatekeeper curl + SHA-256 verification (sha256sum / shasum -a 256)\n'
if command -v zig >/dev/null 2>&1; then
    printf '[ZIG] Detected zig compiler (%s) — < 1 s C11 source build supported\n' "$(command -v zig)"
else
    printf '[ZIG] zig not found on PATH; will install verified prebuilt artifacts\n'
fi

if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would create directory: %s\n' "$INSTALL_DIR"
    printf '[DRY-RUN] Manifest URL: %s\n' "$MANIFEST_URL"
    printf '[DRY-RUN] Would fetch %s/sectium-es [sha256=%s]\n' "$BASE_URL" "$SHA256_SECTIUM_ES"
    printf '[DRY-RUN] Would fetch %s/sectium-jvm [sha256=%s]\n' "$BASE_URL" "$SHA256_SECTIUM_JVM"
    printf '[DRY-RUN] Would fetch %s/sectium-jvm.wasm [sha256=%s]\n' "$BASE_URL" "$SHA256_SECTIUM_JVM_WASM"
    printf '[DRY-RUN] Would fetch %s/libsectium_cp.so [sha256=%s]\n' "$BASE_URL" "$SHA256_LIBSECTIUM_CP"
    printf '[DRY-RUN] Would fetch %s/sectium_cp.wasm [sha256=%s]\n' "$BASE_URL" "$SHA256_SECTIUM_CP_WASM"
    if [ "$OS_NAME" = "Darwin" ]; then
        printf '[DRY-RUN] Would strip com.apple.quarantine and ad-hoc sign via codesign on Apple Silicon\n'
    fi
    printf '[DONE] Dry-run complete (0 files modified, 0 network requests).\n'
    exit 0
fi

mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || printf '')"
WORKSPACE_ROOT=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/../../sections/sectium-cloud-control-plane/sectium_cp.c" ]; then
    WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

BUILT_FROM_SOURCE=0
if [ "$FROM_SOURCE" = "1" ] && [ -n "$WORKSPACE_ROOT" ]; then
    if build_from_source_zig "$WORKSPACE_ROOT"; then
        BUILT_FROM_SOURCE=1
    fi
fi

if [ "$BUILT_FROM_SOURCE" = "0" ]; then
    if [ "$OS_NAME" = "Darwin" ] && command -v zig >/dev/null 2>&1 && [ -n "$WORKSPACE_ROOT" ]; then
        build_from_source_zig "$WORKSPACE_ROOT" || true
    else
        fetch_and_verify "sectium-es" "$SHA256_SECTIUM_ES" "1"
        fetch_and_verify "sectium-jvm" "$SHA256_SECTIUM_JVM" "1"
        fetch_and_verify "libsectium_cp.so" "$SHA256_LIBSECTIUM_CP" "0"
    fi
    fetch_and_verify "sectium-jvm.wasm" "$SHA256_SECTIUM_JVM_WASM" "0"
    fetch_and_verify "sectium_cp.wasm" "$SHA256_SECTIUM_CP_WASM" "0"
fi

ensure_path_entry
printf '[DONE] Sectium installed to %s (channel=%s).\n' "$INSTALL_DIR" "$CHANNEL"
exit 0
