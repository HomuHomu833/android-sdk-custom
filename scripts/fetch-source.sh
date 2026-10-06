#!/usr/bin/env bash
# Clone the repos.json projects the release $TAG has (per its manifest, as
# they move between releases), then run patch-source.sh.
# Env: TAG (android-* or platform-tools-* tag), ROOTDIR, TARGET.
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

# "<local dir>\t<project name>\t<sparse patterns>" for each repos.json entry
# this release has. "sparse" holds git's non-cone patterns for projects whose
# tests/data we skip; "/**/*.bp" goes last so the builder still sees every .bp.
PLAN="$(python3 - "$MANIFEST/default.xml" repos.json <<'PY'
import json, sys, xml.etree.ElementTree as ET
projects = {}
for p in ET.parse(sys.argv[1]).getroot().iter("project"):
    projects[p.get("path") or p.get("name")] = p.get("name")
for r in json.load(open(sys.argv[2])):
    name = projects.get(r["aosp"])
    if name:
        print("%s\t%s\t%s" % (r["path"], name, " ".join(r.get("sparse", []))))
    else:
        print("skip: %s is not part of this release" % r["aosp"], file=sys.stderr)
PY
)"

# --- clone (shallow, detached) -------------------------------------------------
log "Cloning AOSP sources @ $TAG"
# patch-source.sh's aliases of older locations (src/adb -> core/adb, ...) are
# removed when it exits; drop any an interrupted run left, or they would pass
# for the projects they stand in for.
find src -maxdepth 1 -type l -delete 2>/dev/null || true
printf '%s\n' "$PLAN" | while IFS="$(printf '\t')" read -r path name sparse; do
  [ -n "$path" ] || continue
  if [ -d "$path" ]; then
    log "exists: $path"
  elif [ -n "$sparse" ]; then
    # Blobless, so only the checked-out paths' contents come down.
    log "clone:  $path ($name, sparse)"
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$TAG" \
      --filter=blob:none --no-checkout "$AOSP/$name" "$path"
    # One pattern per word, left unglobbed (they are git's, not the shell's).
    set -f
    # shellcheck disable=SC2086
    git -C "$path" sparse-checkout set --no-cone $sparse
    set +f
    git -C "$path" checkout -q
  else
    log "clone:  $path ($name)"
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$TAG" "$AOSP/$name" "$path"
  fi
done

# --- libusb for the BSDs ------------------------------------------------------
# libusb before 1.0.24 (platform-tools 30.0.5 and earlier) picks its backend by
# OS macro, has no events_posix.c and an older backend API, none of which the
# BSD overlay and backends fit. adb only uses libusb's public API, so take the
# platform-tools-31.0.0 libusb there.
case "${TARGET:-}" in
  *-freebsd-*|*-netbsd-*|*-openbsd-*)
    if [ -d src/libusb ] && [ ! -f src/libusb/libusb/os/events_posix.c ]; then
      log "BSD: libusb from platform-tools-31.0.0 (this release's predates 1.0.24)"
      rm -rf src/libusb
      git clone -q -c advice.detachedHead=false --depth 1 --branch platform-tools-31.0.0 \
        "$AOSP/platform/external/libusb" src/libusb
    fi ;;
esac

# --- in-place source fixups -------------------------------------------------
TAG="$TAG" TARGET="${TARGET:-}" ROOTDIR="$ROOTDIR" "$SCRIPT_DIR/patch-source.sh"

log "Sources ready under $ROOTDIR/src"
