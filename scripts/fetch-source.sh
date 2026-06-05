#!/usr/bin/env bash
# Clone the AOSP sources listed in repos.json, drop in the prebuilt patch files,
# and rewrite the proto include paths — the sh port of the old get_source.py.
# Then hand off to patch-source.sh for the in-place source fixups.
#
#   TAG       AOSP source tag/branch to clone (default: master)
#   ROOTDIR   checkout root holding repos.json / patches/ (default: cwd)
#   TARGET    target triple, forwarded to patch-source.sh (optional here)
#
# Runs identically in CI and in `docker run`.
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
TAG="${TAG:-master}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- clone every repo from repos.json (shallow, detached) -------------------
log "Cloning AOSP sources @ $TAG"
jq -r '.[] | "\(.path)\t\(.url)"' repos.json | while IFS="$(printf '\t')" read -r path url; do
  [ -n "$path" ] || continue
  if [ -d "$path" ]; then
    log "exists: $path"
  else
    log "clone:  $path"
    git clone -c advice.detachedHead=false --depth 1 --branch "$TAG" "$url" "$path"
  fi
done

# --- drop in the prebuilt patch files (get_source.py:patches()) -------------
log "Installing patch files"
mkdir -p src/incremental_delivery/sysprop/include
cp patches/misc/IncrementalProperties.sysprop.h   src/incremental_delivery/sysprop/include/
cp patches/misc/IncrementalProperties.sysprop.cpp src/incremental_delivery/sysprop/

cp patches/misc/deployagent.inc        src/adb/fastdeploy/deployagent/
cp patches/misc/deployagentscript.inc  src/adb/fastdeploy/deployagent/

cp patches/misc/platform_tools_version.h src/soong/cc/libbuildversion/include/

cp patches/misc/instruction_set.h        src/art/libartbase/arch/instruction_set.h
cp patches/misc/instruction_set.cc       src/art/libartbase/arch/instruction_set.cc
cp patches/misc/instruction_set_test.cc  src/art/libartbase/arch/instruction_set_test.cc
cp patches/misc/mem_map.h                src/art/libartbase/base/mem_map.h

cp patches/misc/target.h            src/boringssl/src/include/openssl/target.h
cp patches/misc/getrandom_fillin.h  src/boringssl/src/crypto/fipsmodule/rand/getrandom_fillin.h

cp patches/misc/unscaledcycleclock.cc  src/abseil-cpp/absl/base/internal/unscaledcycleclock.cc

cp patches/misc/CombinedIterator.h  src/base/libs/androidfw/include/androidfw/CombinedIterator.h

# aapt2 proto include-path rewrites
sed -i 's#frameworks/base/tools/aapt2/Resources.proto#Resources.proto#g'         src/base/tools/aapt2/ApkInfo.proto
sed -i 's#frameworks/base/tools/aapt2/Configuration.proto#Configuration.proto#g'  src/base/tools/aapt2/Resources.proto
sed -i 's#frameworks/base/tools/aapt2/Configuration.proto#Configuration.proto#g'  src/base/tools/aapt2/ResourcesInternal.proto
sed -i 's#frameworks/base/tools/aapt2/Resources.proto#Resources.proto#g'          src/base/tools/aapt2/ResourcesInternal.proto

# point abseil at our in-tree googletest
sed -i 's#/usr/src/googletest#${CMAKE_SOURCE_DIR}/src/googletest#g' src/abseil-cpp/CMakeLists.txt

# boringssl pulls googletest from its own third_party dir
ln -sf "$ROOTDIR/src/googletest" "$ROOTDIR/src/boringssl/src/third_party/googletest"

# --- in-place source fixups -------------------------------------------------
TARGET="${TARGET:-}" ROOTDIR="$ROOTDIR" "$SCRIPT_DIR/patch-source.sh"

log "Sources ready under $ROOTDIR/src"
