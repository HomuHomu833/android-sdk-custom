#!/bin/bash
TARGET=aarch64-freebsd-none
echo "Testing: $TARGET"
case "$TARGET" in
  aarch64-*-freebsd-*) echo "  old pattern: MATCH" ;;
  *) echo "  old pattern: no match" ;;
esac
case "$TARGET" in
  aarch64-*freebsd*) echo "  new pattern: MATCH" ;;
  *) echo "  new pattern: no match" ;;
esac
