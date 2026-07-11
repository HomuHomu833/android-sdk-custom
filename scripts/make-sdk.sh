#!/usr/bin/env bash
# Splice the freshly cross-built host tools into Google's official Android SDK
# (build-tools + platform-tools) and archive the result.
#
#   TARGET               target triple (names the artifact, locates the binaries)
#   BUILT_BIN            dir of built host tools (default: $OUT/bin-$TARGET)
#   BUILD_TOOLS_VERSION  sdkmanager build-tools package (default: 37.0.0)
#   CMDLINE_TOOLS_URL    commandline-tools zip (default: linux 13114758)
#   ROOTDIR              work dir (default: cwd)
#   DEST                 where the archive is written (default: $ROOTDIR)
#                        windows -> .7z, everything else -> .tar.xz
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${TARGET:?set TARGET}"
PLATFORM="${PLATFORM:-linux}"
OUT="${OUT:-$ROOTDIR/out}"
BUILT_BIN="${BUILT_BIN:-$OUT/bin-$TARGET}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-37.0.0}"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}"
DEST="${DEST:-$ROOTDIR}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Re-run aria2c on any failure so transient GitHub 5xx recover (older aria2 lacks
# --retry-on-unknown). Args pass through, e.g. fetch --dir=. -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

[ -d "$BUILT_BIN" ] || { echo "built binaries not found at $BUILT_BIN" >&2; exit 1; }

# REPO_OS_OVERRIDE makes sdkmanager fetch a specific OS's packages so each
# platform gets the matching SDK to splice into. bionic/BSD reuse the Linux SDK.
case "$PLATFORM" in
  windows) REPO_OS_OVERRIDE=windows ;;
  macos)   REPO_OS_OVERRIDE=macosx ;;
  *)       REPO_OS_OVERRIDE=linux ;;
esac
export REPO_OS_OVERRIDE

# --- fetch the official SDK (build-tools + platform-tools) -------------------
log "Setting up host Android SDK (build-tools $BUILD_TOOLS_VERSION)"
HOST_SDK="$ROOTDIR/android-sdk"
rm -rf "$HOST_SDK"; mkdir -p "$HOST_SDK"
( cd "$HOST_SDK"
  fetch --dir=. -o commandlinetools.zip "$CMDLINE_TOOLS_URL"
  unzip -q commandlinetools.zip
  rm commandlinetools.zip
  # Bounded "y" stream, not `yes`: under pipefail `yes` takes SIGPIPE (141) when
  # sdkmanager closes stdin, aborting the script.
  printf 'y\n%.0s' {1..100} | cmdline-tools/bin/sdkmanager --sdk_root=. --licenses
  cmdline-tools/bin/sdkmanager --sdk_root=. "build-tools;$BUILD_TOOLS_VERSION" "platform-tools" )

# --- splice our ELF host tools over the official ones -----------------------
log "Splicing custom host tools into the SDK"
splice() {
  local dir="$1"
  find "$dir" -type f | while IFS= read -r file; do
    bname="$(basename "$file")"
    if [ -f "$BUILT_BIN/$bname" ] && file "$file" | grep -qE 'ELF|Mach-O|PE32'; then
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
rm -rf "$BT"/*-ld "$BT"/lld* "$BT"/llvm-rs-cc* "$BT"/bcc_compat* "$BT"/renderscript*

# --- drop now-useless DLLs (windows base) -----------------------------------
# AdbWin*Api (we use libusb), libwinpthread-1 (static), RenderScript libs (pruned above).
rm -f "$HOST_SDK/platform-tools/AdbWinApi.dll" "$HOST_SDK/platform-tools/AdbWinUsbApi.dll"
rm -f "$BT/libbcc.dll" "$BT/libbcinfo.dll" "$BT/libclang_android.dll" "$BT/libLLVM_android.dll"
find "$HOST_SDK" -name 'libwinpthread-1.dll' -delete 2>/dev/null || true

# --- convert the bash launcher scripts to POSIX sh --------------------------
# Unix-host SDKs ship bash launchers; windows ships .bat, so skip there.
if [ "$PLATFORM" != windows ]; then
  sed -i -e '1s|^#!.*bash|#!/bin/sh|' \
         -e 's/^declare -a javaOpts=()/javaOpts=""/' \
         -e 's/javaOpts+=("-\${opt}")/javaOpts="\$javaOpts -\${opt}"/' \
         -e 's/javaOpts+=("\${defaultMx}")/javaOpts="\$javaOpts \${defaultMx}"/' \
         -e 's|"\${javaOpts\[@\]}"|$javaOpts|' "$BT/d8"
  sed -i '1s|^#!.*bash|#!/bin/sh|' "$BT/apksigner"
fi

# --- archive ----------------------------------------------------------------
mkdir -p "$DEST"
if [ "$PLATFORM" = windows ]; then
  ARCHIVE="$DEST/android-sdk-$TARGET.7z"
  log "Archiving -> $ARCHIVE"
  rm -f "$ARCHIVE"
  ( cd "$ROOTDIR"
    7z a -snl -t7z -mx=9 -m0=LZMA2 -md=256m -mfb=273 -mtc=on -mmt=on "$ARCHIVE" android-sdk >/dev/null )
else
  ARCHIVE="$DEST/android-sdk-$TARGET.tar.xz"
  log "Archiving -> $ARCHIVE"
  tar -cf - -C "$ROOTDIR" android-sdk | xz -T0 -9e --lzma2=dict=256MiB > "$ARCHIVE"
fi
log "Done -> $ARCHIVE"
