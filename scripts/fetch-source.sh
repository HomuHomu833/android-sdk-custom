#!/usr/bin/env bash
# Clone the AOSP projects the SDK tools are built from, then hand off to
# patch-source.sh for the in-place source fixups. Runs identically in CI and in
# `docker run`.
#
#   TAG       AOSP tag/branch to build (default: master), e.g. android-17.0.0_r1
#             or any platform-tools-* tag
#   ROOTDIR   checkout root holding repos.json / patches/ (default: cwd)
#   TARGET    target triple, forwarded to patch-source.sh (optional here)
#
# Where things live moves between releases (adb left system/core for
# packages/modules/adb, libbase became system/libbase, ...). repos.json lists
# every project the tools need in any release, keyed by AOSP path; the manifest
# of $TAG says which of them this release has, and under which project name.
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
TAG="${TAG:-master}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
AOSP="https://android.googlesource.com"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- the release's manifest ---------------------------------------------------
MANIFEST="$ROOTDIR/.manifest"
if [ ! -f "$MANIFEST/default.xml" ] || [ "$(cat "$MANIFEST/.tag" 2>/dev/null)" != "$TAG" ]; then
  log "Fetching the $TAG manifest"
  rm -rf "$MANIFEST"
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$TAG" "$AOSP/platform/manifest" "$MANIFEST"
  echo "$TAG" > "$MANIFEST/.tag"
fi

# "<local dir>\t<project name>" for each repos.json entry this release has.
PLAN="$(python3 - "$MANIFEST/default.xml" repos.json <<'PY'
import json, sys, xml.etree.ElementTree as ET
projects = {}
for p in ET.parse(sys.argv[1]).getroot().iter("project"):
    projects[p.get("path") or p.get("name")] = p.get("name")
for r in json.load(open(sys.argv[2])):
    name = projects.get(r["aosp"])
    if name:
        print("%s\t%s" % (r["path"], name))
    else:
        print("skip: %s is not part of this release" % r["aosp"], file=sys.stderr)
PY
)"

# --- clone (shallow, detached) -------------------------------------------------
log "Cloning AOSP sources @ $TAG"
printf '%s\n' "$PLAN" | while IFS="$(printf '\t')" read -r path name; do
  [ -n "$path" ] || continue
  if [ -d "$path" ]; then
    log "exists: $path"
  else
    log "clone:  $path ($name)"
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$TAG" "$AOSP/$name" "$path"
  fi
done

# --- in-place source fixups -------------------------------------------------
TARGET="${TARGET:-}" ROOTDIR="$ROOTDIR" "$SCRIPT_DIR/patch-source.sh"

log "Sources ready under $ROOTDIR/src"
