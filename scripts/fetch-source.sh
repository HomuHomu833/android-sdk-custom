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

# --- in-place source fixups -------------------------------------------------
TARGET="${TARGET:-}" ROOTDIR="$ROOTDIR" "$SCRIPT_DIR/patch-source.sh"

log "Sources ready under $ROOTDIR/src"
