#!/bin/zsh
# setup_tools.sh — Install all required host tools for vphone-cli
#
# Installs brew packages, builds trustcache from source,
# builds insert_dylib from submodule source, and creates Python venv
# (including pymobiledevice3 restore/usbmux tooling).
#
# Run: make setup_tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_PREFIX="${TOOLS_PREFIX:-$PROJECT_DIR/.tools}"
REPOS_DIR="$SCRIPT_DIR/repos"
VARIANT="${VARIANT:-}"

refresh_all_submodules() {
    echo "[1/6] Refreshing git submodules..."
    git -C "$PROJECT_DIR" submodule sync --recursive
    git -C "$PROJECT_DIR" submodule update --init --recursive
}

ensure_repo_submodule() {
    local rel_path="$1"
    local abs_path="$PROJECT_DIR/$rel_path"

    if [[ ! -e "$abs_path/.git" ]]; then
        git -C "$PROJECT_DIR" submodule update --init --recursive "$rel_path"
    fi
}

# ── Brew packages ──────────────────────────────────────────────

refresh_all_submodules

echo "[2/6] Checking brew packages..."

BREW_PACKAGES=(aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw git-lfs python@3.13)
BREW_MISSING=()

for pkg in "${BREW_PACKAGES[@]}"; do
    if ! brew list --formula "$pkg" &>/dev/null; then
        BREW_MISSING+=("$pkg")
    fi
done

if ((${#BREW_MISSING[@]} > 0)); then
    echo "  Installing: ${BREW_MISSING[*]}"
    brew install "${BREW_MISSING[@]}"
else
    echo "  All brew packages installed"
fi

# ── Trustcache ─────────────────────────────────────────────────

echo "[3/6] trustcache"

TRUSTCACHE_BIN="$TOOLS_PREFIX/bin/trustcache"
if [[ -x "$TRUSTCACHE_BIN" ]]; then
    echo "  Already built: $TRUSTCACHE_BIN"
else
    echo "  Building from submodule source (scripts/repos/trustcache)..."
    ensure_repo_submodule "scripts/repos/trustcache"

    BUILD_DIR=$(mktemp -d)
    trap "rm -rf '$BUILD_DIR'" EXIT

    ditto "$REPOS_DIR/trustcache" "$BUILD_DIR/trustcache"
    rm -rf "$BUILD_DIR/trustcache/.git"

    OPENSSL_PREFIX="$(brew --prefix openssl@3)"
    make -C "$BUILD_DIR/trustcache" \
        OPENSSL=1 \
        CFLAGS="-I$OPENSSL_PREFIX/include -DOPENSSL -w" \
        LDFLAGS="-L$OPENSSL_PREFIX/lib" \
        -j"$(sysctl -n hw.logicalcpu)" >/dev/null 2>&1

    mkdir -p "$TOOLS_PREFIX/bin"
    cp "$BUILD_DIR/trustcache/trustcache" "$TRUSTCACHE_BIN"
    echo "  Installed: $TRUSTCACHE_BIN"
fi

# ── insert_dylib ───────────────────────────────────────────────

echo "[4/6] insert_dylib"

INSERT_DYLIB_BIN="$TOOLS_PREFIX/bin/insert_dylib"
if [[ -x "$INSERT_DYLIB_BIN" ]]; then
    echo "  Already built: $INSERT_DYLIB_BIN"
else
    INSERT_DYLIB_DIR="$REPOS_DIR/insert_dylib"
    ensure_repo_submodule "scripts/repos/insert_dylib"
    echo "  Building insert_dylib..."
    mkdir -p "$TOOLS_PREFIX/bin"
    clang -o "$INSERT_DYLIB_BIN" "$INSERT_DYLIB_DIR/insert_dylib/main.c" -framework Security -O2
    echo "  Installed: $INSERT_DYLIB_BIN"
fi

# ── Python venv ────────────────────────────────────────────────

echo "[5/6] Python venv"
zsh "$SCRIPT_DIR/setup_venv.sh"

# ── APFS sealvolume (patchless variant only) ──────────────────────

if [[ "$VARIANT" == "less" ]]; then
    echo "[6/6] apfs sealvolume"
    if [[ -f "$TOOLS_PREFIX/apfs_sealvolume" ]]; then
        echo "  apfs_sealvolume already present"
    else
        TMP_DIR="$(mktemp -d)"
        ipsw download appledb \
        --os macOS \
        --build 25D2140 \
        --pattern "094-33864-054.dmg" \
        --output "$TMP_DIR"

        RAMDISK_IM4P="$TMP_DIR/25D2140__MacOS/094-33864-054.dmg"
        RAMDISK="$TMP_DIR/ramdisk.dmg"
        ipsw img4 im4p extract --output "$RAMDISK" "$RAMDISK_IM4P"

        MOUNT=$(hdiutil attach -readonly -nobrowse "$RAMDISK" | awk 'END{ print$NF}')
        cp "$MOUNT/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_sealvolume" \
        "$TOOLS_PREFIX/apfs_sealvolume"
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
        rm -rf "$TMP_DIR"
        echo "  Downloaded: $TOOLS_PREFIX/apfs_sealvolume"
        echo "  Resigning apfs_sealvolume"
        codesign --force --sign - "$TOOLS_PREFIX/apfs_sealvolume"
    fi
else
    echo "[6/6] apfs sealvolume (skipped — patchless variant only)"
fi

echo ""
echo "All tools installed."
