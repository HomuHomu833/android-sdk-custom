#!/usr/bin/env bash
# Splice the freshly cross-built host tools into Google's official Android SDK
# (build-tools + platform-tools) and archive the result — the sh port of the
# "make" job in the old make_sdk.yml.
#
#   TARGET               target triple (names the artifact, locates the binaries)
#   BUILT_BIN            dir holding the built host tools (default: $OUT/bin-$TARGET)
#   BUILD_TOOLS_VERSION  sdkmanager build-tools package (default: 36.1.0)
#   CMDLINE_TOOLS_URL    commandline-tools zip (default: linux 13114758)
#   ROOTDIR              work dir (default: cwd)
#   DEST                 where the .tar.xz is written (default: $ROOTDIR)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${TARGET:?set TARGET}"
OUT="${OUT:-$ROOTDIR/out}"
BUILT_BIN="${BUILT_BIN:-$OUT/bin-$TARGET}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-36.1.0}"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}"
DEST="${DEST:-$ROOTDIR}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ -d "$BUILT_BIN" ] || { echo "built binaries not found at $BUILT_BIN" >&2; exit 1; }

# --- fetch the official SDK (build-tools + platform-tools) -------------------
log "Setting up host Android SDK (build-tools $BUILD_TOOLS_VERSION)"
HOST_SDK="$ROOTDIR/android-sdk"
rm -rf "$HOST_SDK"; mkdir -p "$HOST_SDK"
( cd "$HOST_SDK"
  curl -LkSs -o commandlinetools.zip "$CMDLINE_TOOLS_URL"
  unzip -q commandlinetools.zip
  rm commandlinetools.zip
  yes | cmdline-tools/bin/sdkmanager --sdk_root=. --licenses >/dev/null
  cmdline-tools/bin/sdkmanager --sdk_root=. "build-tools;$BUILD_TOOLS_VERSION" "platform-tools" )

# --- splice our ELF host tools over the official ones -----------------------
log "Splicing custom host tools into the SDK"
splice() {
  local dir="$1"
  find "$dir" -type f | while IFS= read -r file; do
    bname="$(basename "$file")"
    if [ -f "$BUILT_BIN/$bname" ] && file "$file" | grep -q 'ELF'; then
      echo "Replacing $bname"
      cp "$BUILT_BIN/$bname" "$file"
    fi
  done
}
BT="$HOST_SDK/build-tools/$BUILD_TOOLS_VERSION"
splice "$BT"
splice "$HOST_SDK/platform-tools"

# --- prune host-only / renderscript leftovers -------------------------------
rm -rf "$BT/lib64" "$HOST_SDK/platform-tools/lib64"
rm -rf "$BT"/*-ld "$BT"/lld* "$BT"/llvm-rs-cc "$BT"/bcc_compat "$BT"/renderscript

# --- convert the bash launcher scripts to POSIX sh --------------------------
sed -i -e '1s|^#!.*bash|#!/bin/sh|' \
       -e 's/^declare -a javaOpts=()/javaOpts=""/' \
       -e 's/javaOpts+=("-\${opt}")/javaOpts="\$javaOpts -\${opt}"/' \
       -e 's/javaOpts+=("\${defaultMx}")/javaOpts="\$javaOpts \${defaultMx}"/' \
       -e 's|"\${javaOpts\[@\]}"|$javaOpts|' "$BT/d8"
sed -i '1s|^#!.*bash|#!/bin/sh|' "$BT/apksigner"

# --- archive ----------------------------------------------------------------
mkdir -p "$DEST"
ARCHIVE="$DEST/android-sdk-$TARGET.tar.xz"
log "Archiving -> $ARCHIVE"
tar -cf - -C "$ROOTDIR" android-sdk | xz -T0 -9e --lzma2=dict=256MiB > "$ARCHIVE"
log "Done -> $ARCHIVE"
