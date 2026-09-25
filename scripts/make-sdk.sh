#!/usr/bin/env bash
# Splice the freshly cross-built host tools into Google's official Android SDK
# (build-tools + platform-tools) and archive the result.
#
#   TARGET               target triple (names the artifact, locates the binaries)
#   BUILT_BIN            dir of built host tools (default: $OUT/bin-$TARGET)
#   PLATFORM_TOOLS_VERSION  official platform-tools revision to splice into
#                        (default: the one the sources declare, in
#                        src/development/sdk/plat_tools_source.prop_template;
#                        the latest when Google has no zip of it)
#   BUILD_TOOLS_VERSION  official build-tools revision (default: the newest
#                        stable one of the same major as platform-tools)
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
PLATFORM_TOOLS_VERSION="${PLATFORM_TOOLS_VERSION:-}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-}"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}"
DEST="${DEST:-$ROOTDIR}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Re-run aria2c on any failure so transient GitHub 5xx recover (older aria2 lacks
# --retry-on-unknown). Args pass through, e.g. fetch --dir=. -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 \
               --allow-overwrite=true --auto-file-renaming=false "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

# Unpack ARCHIVE into DEST, picking the tool from the extension.
unpack() {
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
    *.tar.xz)       tar -xJf "$1" -C "$2" ;;
    *.tar.bz2)      tar -xjf "$1" -C "$2" ;;
    *.zip)          unzip -qq -o "$1" -d "$2" ;;
    *) echo "unpack: don't know how to unpack $1" >&2; return 1 ;;
  esac
}

# Download URL to ARCHIVE and unpack it into DEST (default: the current
# directory), re-downloading when the unpack fails. ARCHIVE is removed on the
# way out. Usage: fetch_unpack URL ARCHIVE [DEST]
#
# aria2c's own retries cannot see a truncated download. Endpoints that generate
# archives on the fly, such as codeload, stream them chunked with
# no Content-Length (aria2 logs the size as "0B/0B"), so when the far end cuts
# the stream short there is no expected size to compare against: aria2 prints
# "(OK):download completed" and exits 0 on a 600KiB truncation of a 200MiB
# archive, and the damage only surfaces further down as "gzip: stdin:
# unexpected end of file". Unpacking is the only integrity check available, so
# the retry has to wrap the download and the unpack together.
fetch_unpack() {
  local url="$1" archive="$2" dest="${3:-.}" i=0
  mkdir -p "$dest"
  while :; do
    rm -f "$archive" "$archive.aria2"
    if fetch --dir="$(dirname "$archive")" -o "$(basename "$archive")" "$url" \
       && unpack "$archive" "$dest"; then
      rm -f "$archive"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge 5 ] && { echo "fetch_unpack: $url still incomplete after $i attempts" >&2; return 1; }
    echo "fetch_unpack: $(basename "$archive") came down incomplete, retry $i/5 in $((5 * i))s..." >&2
    sleep $((5 * i))
  done
}

[ -d "$BUILT_BIN" ] || { echo "built binaries not found at $BUILT_BIN" >&2; exit 1; }

# REPO_OS_OVERRIDE makes sdkmanager fetch a specific OS's packages so each
# platform gets the matching SDK to splice into. bionic/BSD reuse the Linux SDK.
# PT_OS is the same OS as Google's platform-tools zips name it.
case "$PLATFORM" in
  windows) REPO_OS_OVERRIDE=windows; PT_OS=windows ;;
  macos)   REPO_OS_OVERRIDE=macosx;  PT_OS=darwin ;;
  *)       REPO_OS_OVERRIDE=linux;   PT_OS=linux ;;
esac
export REPO_OS_OVERRIDE

# The platform-tools revision the sources declare: what adb/fastboot --version
# report, and the official package the tools go into.
PT_TEMPLATE="$ROOTDIR/src/development/sdk/plat_tools_source.prop_template"
if [ -z "$PLATFORM_TOOLS_VERSION" ] && [ -f "$PT_TEMPLATE" ]; then
  PLATFORM_TOOLS_VERSION="$(sed -n 's/^Pkg\.Revision=//p' "$PT_TEMPLATE" | tr -d '\r')"
fi

# sdkmanager runs on the linux cmdline-tools, but the copy we *ship* must match
# $PLATFORM. Derive that zip from CMDLINE_TOOLS_URL; SHIP_CMDLINE_TOOLS_URL pins
# a different build.
case "$PLATFORM" in
  windows) CMDLINE_TOOLS_OS=win ;;
  macos)   CMDLINE_TOOLS_OS=mac ;;
  *)       CMDLINE_TOOLS_OS=linux ;;
esac
SHIP_CMDLINE_TOOLS_URL="${SHIP_CMDLINE_TOOLS_URL:-${CMDLINE_TOOLS_URL/commandlinetools-linux-/commandlinetools-$CMDLINE_TOOLS_OS-}}"

# --- fetch the official SDK (build-tools + platform-tools) -------------------
HOST_SDK="$ROOTDIR/android-sdk"
SDKMANAGER="$HOST_SDK/cmdline-tools/bin/sdkmanager"
rm -rf "$HOST_SDK"; mkdir -p "$HOST_SDK"
fetch_unpack "$CMDLINE_TOOLS_URL" "$HOST_SDK/commandlinetools.zip" "$HOST_SDK"
# Bounded "y" stream, not `yes`: under pipefail `yes` takes SIGPIPE (141) when
# sdkmanager closes stdin, aborting the script.
printf 'y\n%.0s' {1..100} | "$SDKMANAGER" --sdk_root="$HOST_SDK" --licenses

# platform-tools: Google keeps every released revision's zip, while sdkmanager
# only offers the latest. Revisions that never shipped (or a tag without the
# template) get the latest.
PT_URL="https://dl.google.com/android/repository/platform-tools_r${PLATFORM_TOOLS_VERSION}-${PT_OS}.zip"
if [ -n "$PLATFORM_TOOLS_VERSION" ] \
   && aria2c --dry-run=true --console-log-level=error --max-tries=3 "$PT_URL" >/dev/null 2>&1; then
  PT_LATEST=""; PT_DESC="$PLATFORM_TOOLS_VERSION"
else
  log "No official platform-tools ${PLATFORM_TOOLS_VERSION:-(unknown)} for $PT_OS; using the latest"
  PT_LATEST=platform-tools; PT_DESC=latest
fi

# build-tools: sdkmanager lists them all. Take the newest stable one of the
# platform-tools major (same AOSP generation as the aapt2/aidl/dexdump built
# here), else the newest stable overall.
if [ -z "$BUILD_TOOLS_VERSION" ]; then
  BT_AVAIL="$("$SDKMANAGER" --sdk_root="$HOST_SDK" --list 2>/dev/null \
    | sed -n 's/^ *build-tools;\([0-9][0-9.]*\) .*/\1/p' | sort -uV)"
  BUILD_TOOLS_VERSION="$(printf '%s\n' "$BT_AVAIL" | grep "^${PLATFORM_TOOLS_VERSION%%.*}\." | tail -n1 || true)"
  [ -n "$BUILD_TOOLS_VERSION" ] || BUILD_TOOLS_VERSION="$(printf '%s\n' "$BT_AVAIL" | tail -n1)"
fi
[ -n "$BUILD_TOOLS_VERSION" ] || { echo "no build-tools revision to install" >&2; exit 1; }

log "Setting up the official SDK: build-tools $BUILD_TOOLS_VERSION, platform-tools $PT_DESC"
"$SDKMANAGER" --sdk_root="$HOST_SDK" "build-tools;$BUILD_TOOLS_VERSION" $PT_LATEST
[ -n "$PT_LATEST" ] || fetch_unpack "$PT_URL" "$HOST_SDK/platform-tools.zip" "$HOST_SDK"

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

# --- official binaries we did not rebuild -----------------------------------
# Anything native still at the top of either package is Google's own build
# (x86-64, and missing the lib64 pruned above), so it would not run on most
# targets. Ship ours or nothing: drop it, and say so.
drop_unreplaced() {
  find "$1" -maxdepth 1 -type f | while IFS= read -r file; do
    [ -f "$BUILT_BIN/$(basename "$file")" ] && continue
    if file "$file" | grep -qE 'ELF|Mach-O|PE32'; then
      echo "Dropping $(basename "$file"): official build, not rebuilt for $TARGET"
      rm -f "$file"
    fi
  done
}
drop_unreplaced "$BT"
drop_unreplaced "$HOST_SDK/platform-tools"

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

# --- swap linux build scaffolding for OS-matching cmdline-tools -------------
# Replace the linux cmdline-tools we drove sdkmanager with by the $PLATFORM copy,
# so the archive isn't a mix (.temp is scaffolding too). On linux the URLs match,
# so keep what we downloaded.
rm -rf "$HOST_SDK/.temp"
if [ "$SHIP_CMDLINE_TOOLS_URL" != "$CMDLINE_TOOLS_URL" ]; then
  rm -rf "$HOST_SDK/cmdline-tools"
  ( cd "$HOST_SDK"
    fetch_unpack "$SHIP_CMDLINE_TOOLS_URL" "$PWD/cmdline-tools.zip" )
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
