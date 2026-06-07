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
PLATFORM="${PLATFORM:-linux}"
OUT="${OUT:-$ROOTDIR/out}"
BUILT_BIN="${BUILT_BIN:-$OUT/bin-$TARGET}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-36.1.0}"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}"
DEST="${DEST:-$ROOTDIR}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Download with retries: re-run aria2c on any failure so transient GitHub 501/504
# (and the like) recover. Doesn't rely on aria2's --retry-on-unknown, which older
# aria2 builds don't have. Pass aria2c args, e.g. fetch --dir=. -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

[ -d "$BUILT_BIN" ] || { echo "built binaries not found at $BUILT_BIN" >&2; exit 1; }

# --- windows: ship the raw .exe tools ---------------------------------------
# The official SDK's per-OS build-tools can't be fetched on the Linux build host
# (sdkmanager only pulls the host OS's package), and the launcher scripts are
# bash, not .bat. So the Windows deliverable is the cross-built tool set; drop it
# into a real Windows SDK on-device. (Linux/macOS/bionic splice below: same binary
# names + universal Java/shell tooling make the official Linux SDK a valid base.)
if [ "$PLATFORM" = windows ]; then
  mkdir -p "$DEST"
  ARCHIVE="$DEST/android-sdk-$TARGET.tar.xz"
  log "Archiving windows host tools -> $ARCHIVE"
  tar -cf - -C "$(dirname "$BUILT_BIN")" "$(basename "$BUILT_BIN")" \
    | xz -T0 -9e --lzma2=dict=256MiB > "$ARCHIVE"
  log "Done -> $ARCHIVE"
  exit 0
fi

# --- fetch the official SDK (build-tools + platform-tools) -------------------
log "Setting up host Android SDK (build-tools $BUILD_TOOLS_VERSION)"
HOST_SDK="$ROOTDIR/android-sdk"
rm -rf "$HOST_SDK"; mkdir -p "$HOST_SDK"
( cd "$HOST_SDK"
  fetch --dir=. -o commandlinetools.zip "$CMDLINE_TOOLS_URL"
  unzip -q commandlinetools.zip
  rm commandlinetools.zip
  # Feed a bounded stream of "y" rather than `yes`: under `set -o pipefail`, the
  # infinite `yes` gets SIGPIPE (exit 141) when sdkmanager closes stdin after the
  # last prompt, which would abort the script even though licenses were accepted.
  printf 'y\n%.0s' {1..100} | cmdline-tools/bin/sdkmanager --sdk_root=. --licenses
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
