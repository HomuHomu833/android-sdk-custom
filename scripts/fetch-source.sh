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

# --- in-place source fixups -------------------------------------------------
TARGET="${TARGET:-}" ROOTDIR="$ROOTDIR" "$SCRIPT_DIR/patch-source.sh"

log "Sources ready under $ROOTDIR/src"
