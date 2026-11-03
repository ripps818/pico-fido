#!/usr/bin/env bash
# Reproducible build of pico-fido for the Waveshare RP2350-One.
#
# Usage:
#   SIGNING_KEY=/path/to/primary.pem ./build-rp2350-one.sh   # signed (picotool seal --sign --hash)
#   ./build-rp2350-one.sh                                    # unsigned, prints a warning
#
# Environment:
#   SIGNING_KEY          secp256k1 EC private key (PEM). Never commit it.
#   PICO_SDK_PATH        pico-sdk checkout; must be at tag $PICO_SDK_TAG
#                        (default: cloned to .deps/pico-sdk)
#   ALLOW_SDK_MISMATCH=1 build against a different SDK checkout anyway
#   FORCE_BUTTON_WAIT    1 (default) requires a BOOT press for user presence, 0 = upstream default
#   OUT_DIR              output directory (default /data/out/pico-fido-rp2350-one)
#   PICOTOOL_FETCH_FROM_GIT_PATH
#                        where the SDK caches the picotool it builds (default .deps/picotool)
#
# Credential storage is placed by pico-keys-sdk/config/rp2350/pt.json (data partition,
# clamped to the detected flash size). Nothing here moves it; the sha256 of pt.json and
# all pinned commits are recorded in build-info.txt.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# ---- pinned options -------------------------------------------------------
PICO_BOARD=waveshare_rp2350_one      # RP2350A, 4 MiB, WS2812 on GPIO16 (from pico-sdk)
PICO_PLATFORM=rp2350-arm-s
PICO_SDK_TAG=2.3.1
FORCE_BUTTON_WAIT="${FORCE_BUTTON_WAIT:-1}"
OUT_DIR="${OUT_DIR:-/data/out/pico-fido-rp2350-one}"
BUILD_DIR="$REPO_DIR/build-rp2350-one"
BUILD_TYPE=Release

die() { echo "ERROR: $*" >&2; exit 1; }
for t in cmake ninja git arm-none-eabi-gcc sha256sum; do
    command -v "$t" >/dev/null || die "$t not found in PATH"
done

# ---- pico-sdk -------------------------------------------------------------
if [ -z "${PICO_SDK_PATH:-}" ]; then
    PICO_SDK_PATH="$REPO_DIR/.deps/pico-sdk"
    if [ ! -d "$PICO_SDK_PATH/.git" ]; then
        git clone --branch "$PICO_SDK_TAG" --depth 1 --recurse-submodules --shallow-submodules \
            https://github.com/raspberrypi/pico-sdk "$PICO_SDK_PATH"
    fi
fi
export PICO_SDK_PATH
SDK_DESC="$(git -C "$PICO_SDK_PATH" describe --tags --exact-match 2>/dev/null || echo untagged)"
SDK_COMMIT="$(git -C "$PICO_SDK_PATH" rev-parse HEAD)"
if [ "$SDK_DESC" != "$PICO_SDK_TAG" ] && [ "${ALLOW_SDK_MISMATCH:-0}" != 1 ]; then
    die "pico-sdk at $PICO_SDK_PATH is '$SDK_DESC', expected tag $PICO_SDK_TAG (ALLOW_SDK_MISMATCH=1 to override)"
fi
[ -f "$PICO_SDK_PATH/src/boards/include/boards/$PICO_BOARD.h" ] || die "board header $PICO_BOARD.h missing in SDK"
[ -f "$PICO_SDK_PATH/lib/tinyusb/src/tusb.h" ] || die "tinyusb submodule missing: git -C $PICO_SDK_PATH submodule update --init"

# SDK builds and caches the pinned picotool itself (no libusb needed for seal/uf2).
export PICOTOOL_FETCH_FROM_GIT_PATH="${PICOTOOL_FETCH_FROM_GIT_PATH:-$REPO_DIR/.deps/picotool}"

# ---- submodule ------------------------------------------------------------
git submodule update --init --recursive
if git submodule status | grep -q '^[+-U]'; then
    die "pico-keys-sdk submodule is not at the commit recorded by this checkout"
fi
SUB_COMMIT="$(git -C pico-keys-sdk rev-parse HEAD)"
TREE_COMMIT="$(git rev-parse HEAD)"
DIRTY=clean
[ -n "$(git status --porcelain --untracked-files=no)" ] && DIRTY=DIRTY

# ---- signing key ----------------------------------------------------------
CMAKE_SIGN=()
SIGNED=no
if [ -n "${SIGNING_KEY:-}" ]; then
    [ -r "$SIGNING_KEY" ] || die "SIGNING_KEY=$SIGNING_KEY not readable"
    KEY_ABS="$(readlink -f "$SIGNING_KEY")"
    case "$KEY_ABS/" in "$REPO_DIR"/*)
        git check-ignore -q "$KEY_ABS" || die "signing key is inside the repo and not git-ignored"
        git ls-files --error-unmatch "$KEY_ABS" >/dev/null 2>&1 && die "signing key is tracked by git" ;;
    esac
    command -v openssl >/dev/null || die "openssl needed to validate SIGNING_KEY"
    openssl pkey -in "$KEY_ABS" -noout 2>/dev/null || die "SIGNING_KEY is not a valid PEM private key"
    openssl ec -in "$KEY_ABS" -noout -text 2>/dev/null | grep -q 'secp256k1' \
        || die "SIGNING_KEY must be a secp256k1 EC key (openssl ecparam -name secp256k1 -genkey -noout)"
    CMAKE_SIGN=("-DSECURE_BOOT_PKEY=$KEY_ABS")
    SIGNED=yes
else
    cat >&2 <<'EOF'
################################################################
# WARNING: SIGNING_KEY not set -> building an UNSIGNED image.
# It will NOT boot on a device with secure boot enabled.
################################################################
EOF
fi

# ---- build ----------------------------------------------------------------
CMAKE_ARGS=(
    -G Ninja
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
    "-DPICO_SDK_PATH=$PICO_SDK_PATH"
    "-DPICO_BOARD=$PICO_BOARD"
    "-DPICO_PLATFORM=$PICO_PLATFORM"
)
[ "$FORCE_BUTTON_WAIT" = 1 ] && CMAKE_ARGS+=(-DFORCE_BUTTON_WAIT=1)
CMAKE_ARGS+=("${CMAKE_SIGN[@]}")

rm -rf "$BUILD_DIR"
cmake -S "$REPO_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR"

# ---- collect outputs ------------------------------------------------------
mkdir -p "$OUT_DIR"
for f in pico_fido.uf2 pico_fido.elf pico_fido.elf.map; do
    cp -f "$BUILD_DIR/$f" "$OUT_DIR/$f"
done
if [ "$SIGNED" = yes ]; then
    [ -f "$BUILD_DIR/pico_fido.otp.json" ] && cp -f "$BUILD_DIR/pico_fido.otp.json" "$OUT_DIR/"
else
    rm -f "$OUT_DIR/pico_fido.otp.json"
fi

PICOTOOL="$(find "$PICOTOOL_FETCH_FROM_GIT_PATH" -type f -name picotool -perm -u+x 2>/dev/null | head -1 || true)"
[ -n "$PICOTOOL" ] || PICOTOOL="$(command -v picotool || true)"
{
    echo "build-time:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "pico-fido commit:  $TREE_COMMIT ($DIRTY)"
    echo "pico-keys-sdk:     $SUB_COMMIT"
    echo "pico-sdk:          $SDK_DESC ($SDK_COMMIT)"
    echo "picotool:          ${PICOTOOL:-unknown} $([ -n "$PICOTOOL" ] && "$PICOTOOL" version 2>&1 | head -1)"
    echo "compiler:          $(arm-none-eabi-gcc --version | head -1)"
    echo "cmake:             $(cmake --version | head -1)"
    echo "ninja:             $(ninja --version)"
    echo "cmake options:     ${CMAKE_ARGS[*]}"
    echo "signed:            $SIGNED"
    echo "pt.json sha256:    $(sha256sum pico-keys-sdk/config/rp2350/pt.json | cut -d' ' -f1)"
    echo "pico_fido.uf2 sha256: $(sha256sum "$OUT_DIR/pico_fido.uf2" | cut -d' ' -f1)"
    echo "pico_fido.elf sha256: $(sha256sum "$OUT_DIR/pico_fido.elf" | cut -d' ' -f1)"
    if [ -n "$PICOTOOL" ]; then
        echo; echo "--- picotool info -a ---"
        "$PICOTOOL" info -a "$OUT_DIR/pico_fido.uf2" 2>&1 || true
    fi
} | tee "$OUT_DIR/build-info.txt"

echo
echo "UF2: $OUT_DIR/pico_fido.uf2 (signed: $SIGNED)"
