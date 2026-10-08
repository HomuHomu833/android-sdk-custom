#!/usr/bin/env bash
# Ad-hoc sign the Mach-O files under a directory. Apple Silicon kills a process
# whose code signature is missing or does not match the file; the linker signs
# arm64 output ad hoc, but strip and install_name_tool invalidate that. So every
# unsigned or ad-hoc file is (re)signed ad hoc; files carrying a real signature
# (Apple's, Google's) are left alone. ("rcodesign verify" cannot judge ad-hoc
# signatures, so it is not used.) rcodesign (apple-codesign) is fetched once and
# checked against its sha256.
# Usage: macos-sign.sh <dir>
set -euo pipefail

DIR="${1:?usage: macos-sign.sh <dir>}"
RCS_VERSION=0.29.0
case "$(uname -m)" in
  x86_64)        RCS_ARCH=x86_64;  RCS_SHA256=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002 ;;
  aarch64|arm64) RCS_ARCH=aarch64; RCS_SHA256=4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f ;;
  *) echo "macos-sign.sh: no rcodesign for $(uname -m)" >&2; exit 1 ;;
esac

CACHE="${RCS_CACHE:-${ROOTDIR:-$PWD}/.cache/rcodesign-$RCS_VERSION}"
RCS="$CACHE/rcodesign"
if [ ! -x "$RCS" ]; then
  mkdir -p "$CACHE"
  name="apple-codesign-$RCS_VERSION-$RCS_ARCH-unknown-linux-musl"
  curl -sSfL --retry 5 -o "$CACHE/rcs.tar.gz" \
    "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCS_VERSION/$name.tar.gz"
  echo "$RCS_SHA256  $CACHE/rcs.tar.gz" | sha256sum -c --quiet -
  tar -xzf "$CACHE/rcs.tar.gz" -C "$CACHE" --strip-components=1 "$name/rcodesign"
  rm -f "$CACHE/rcs.tar.gz"
fi

signed=0 kept=0 failed=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^Mach-O' || continue
  info="$("$RCS" print-signature-info "$f" 2>/dev/null || true)"
  if grep -q 'signature:' <<<"$info" && ! grep -q 'ADHOC' <<<"$info"; then
    kept=$((kept + 1))
  elif "$RCS" sign "$f" >/dev/null 2>&1 \
       && "$RCS" print-signature-info "$f" 2>/dev/null | grep -q 'ADHOC'; then
    signed=$((signed + 1))
  else
    echo "macos-sign.sh: could not sign $f" >&2
    failed=$((failed + 1))
  fi
done < <(find "$DIR" -type f -print0)

echo "macos-sign.sh: $signed ad-hoc signed, $kept kept (certificate-signed), $failed failed"
[ "$failed" -eq 0 ]
