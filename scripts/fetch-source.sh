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

# googlesource.com drops a connection now and then (curl 92, early EOF). Run
# "$@" up to 5 times, removing the half-made <dir> before each retry. Steps in
# the functions passed here are chained with && (set -e is off inside them).
with_retry() {
  local dir="$1" n
  shift
  for n in 1 2 3 4 5; do
    "$@" && return 0
    [ "$n" = 5 ] && break
    log "retry $n/4: $dir"
    rm -rf "$dir"
    sleep $((n * 10))
  done
  return 1
}

# clone_shallow <dir> <project> <branch>
clone_shallow() {
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$3" "$AOSP/$2" "$1"
}

# clone_sparse <dir> <project> <patterns>: blobless, so only the checked-out
# paths' contents come down. One pattern per word, left unglobbed (they are
# git's, not the shell's).
clone_sparse() {
  local rc
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$TAG" \
    --filter=blob:none --no-checkout "$AOSP/$2" "$1" || return
  set -f
  # shellcheck disable=SC2086
  git -C "$1" sparse-checkout set --no-cone $3 && git -C "$1" checkout -q
  rc=$?
  set +f
  return $rc
}

# --- the release's manifest ---------------------------------------------------
MANIFEST="$ROOTDIR/.manifest"
if [ ! -f "$MANIFEST/default.xml" ] || [ "$(cat "$MANIFEST/.tag" 2>/dev/null)" != "$TAG" ]; then
  log "Fetching the $TAG manifest"
  rm -rf "$MANIFEST"
  with_retry "$MANIFEST" clone_shallow "$MANIFEST" platform/manifest "$TAG"
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
    log "clone:  $path ($name, sparse)"
    with_retry "$path" clone_sparse "$path" "$name" "$sparse"
  else
    log "clone:  $path ($name)"
    with_retry "$path" clone_shallow "$path" "$name" "$TAG"
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
      with_retry src/libusb clone_shallow src/libusb platform/external/libusb platform-tools-31.0.0
    fi ;;
  # Termux's adb (patches/termux, through rusb) opens USB fds Termux hands it
  # with libusb_wrap_sys_device(), new in libusb 1.0.23; 29.x ships 1.0.21.
  *-linux-android*)
    if [ -f src/libusb/libusb/libusb.h ] && ! grep -q libusb_wrap_sys_device src/libusb/libusb/libusb.h; then
      log "bionic: libusb from platform-tools-31.0.0 (this release's predates 1.0.23)"
      rm -rf src/libusb
      with_retry src/libusb clone_shallow src/libusb platform/external/libusb platform-tools-31.0.0
    fi ;;
esac

# --- in-place source fixups -------------------------------------------------
TAG="$TAG" TARGET="${TARGET:-}" ROOTDIR="$ROOTDIR" "$SCRIPT_DIR/patch-source.sh"

log "Sources ready under $ROOTDIR/src"
