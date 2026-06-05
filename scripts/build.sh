#!/usr/bin/env bash
# Cross-build the Android SDK host tools for one target. Driven entirely by env
# vars so it runs identically in CI and in `docker run`.
#
#   PLATFORM   linux            (only platform wired today; see case below)
#   TARGET     target triple, e.g. x86_64-linux-musl / aarch64-linux-gnu
#   ARCH       CMAKE_SYSTEM_PROCESSOR (default: triple's arch field)
#   ROOTDIR    checkout root (default: cwd)
#   OUT        where the stripped host tools land (default: $ROOTDIR/out)
#   JOBS       parallelism (default: nproc)
#
# Expects fetch-source.sh to have run first (sources + patches in place).
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}"
ARCH="${ARCH:-${TARGET%%-*}}"
OUT="${OUT:-$ROOTDIR/out}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
BUILD_DIR="${BUILD_DIR:-$ROOTDIR/build}"
EXTRA_PREFIX="${EXTRA_PREFIX:-$ROOTDIR/extrabuild}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- toolchain selection ----------------------------------------------------
# Structured as a per-PLATFORM case so windows (llvm-mingw) / macos (osxcross) /
# bionic (NDK clang) can be added the same way the sibling repos do.
case "$PLATFORM" in
  linux)
    TC=/opt/zig-as-llvm
    export ZIG_TARGET="$TARGET"
    # overlay the musl libc source fixes onto zig's bundled musl (lib is a+w)
    [ -d "$ROOTDIR/patches/musl/zig" ] && cp -R "$ROOTDIR/patches/musl/zig/." /opt/zig/ || true
    CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_LD="$TC/bin/ld"
    CROSS_AR="$TC/bin/ar"; CROSS_RANLIB="$TC/bin/ranlib"
    CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"
    SYSTEM_NAME=Linux
    # musl is fully static and needs the LFS/64-bit aliases that musl omits, plus
    # the ANDROID_HOST_MUSL define the AOSP sources key off; glibc ships the LFS
    # aliases natively and links dynamically with just the runtime statified
    # (mirrors how the sibling repos split musl vs gnu).
    case "$TARGET" in
      *musl*)
        CROSS_CFLAGS="-Wno-error=date-time -Doff64_t=off_t -Dmmap64=mmap -Dlseek64=lseek -Dpread64=pread -Dpwrite64=pwrite -Dftruncate64=ftruncate -DANDROID_HOST_MUSL -static"
        CROSS_LDFLAGS="-static" ;;
      *)
        CROSS_CFLAGS="-Wno-error=date-time"
        CROSS_LDFLAGS="-static-libstdc++ -static-libgcc" ;;
    esac
    ;;
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac
export CROSS_CC CROSS_CXX CROSS_LD CROSS_AR CROSS_RANLIB CROSS_STRIP CROSS_OBJCOPY CROSS_LDFLAGS

# --- native protoc (runs on the build host during codegen) ------------------
# Built with the host compiler, NOT the zig cross toolchain, since the cross
# build invokes it at generate time.
PROTOC="$ROOTDIR/src/protobuf/build/protoc"
if [ ! -f "$PROTOC" ]; then
  log "Building native protoc"
  ( cd "$ROOTDIR/src/protobuf/third_party"
    [ -d abseil-cpp ] || git clone https://android.googlesource.com/platform/external/abseil-cpp.git -b "${TAG:-master}" --recursive
    [ -d jsoncpp ]    || git clone https://android.googlesource.com/platform/external/jsoncpp.git    -b "${TAG:-master}" --recursive )
  patch -up1 -d "$ROOTDIR" < "$ROOTDIR/patches/protobuf_CMakeLists.txt.patch" || true
  rm -rf "$ROOTDIR/src/protobuf/build"
  cmake -S "$ROOTDIR/src/protobuf" -B "$ROOTDIR/src/protobuf/build" -GNinja -Dprotobuf_BUILD_TESTS=OFF
  ninja -C "$ROOTDIR/src/protobuf/build" -j"$JOBS"
fi

# --- extra deps (zlib + bzip2, static, cross-compiled for the target) -------
mkdir -p "$EXTRA_PREFIX"
if [ ! -f "$EXTRA_PREFIX/lib/libz.a" ]; then
  log "Building zlib (static, $TARGET)"
  ( cd "$ROOTDIR"
    curl -LkSs https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz | xz -d | tar -x
    cd zlib-1.3.1
    CC="$CROSS_CC" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" ./configure --prefix="$EXTRA_PREFIX" --static
    make -j"$JOBS" install )
fi
if [ ! -f "$EXTRA_PREFIX/lib/libbz2.a" ]; then
  log "Building bzip2 (static, $TARGET)"
  ( cd "$ROOTDIR"
    curl -LkSs https://www.sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz | gzip -d | tar -x
    cd bzip2-1.0.8
    make CC="$CROSS_CC" AR="$CROSS_AR" PREFIX="$EXTRA_PREFIX" CFLAGS="-static" LDFLAGS="-static" install )
fi

# --- the SDK host tools -----------------------------------------------------
log "Configuring SDK ($PLATFORM / $TARGET)"
cmake -GNinja \
  -B "$BUILD_DIR" \
  -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
  -DCMAKE_CROSSCOMPILING=True \
  -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
  -DCMAKE_PREFIX_PATH="$EXTRA_PREFIX" \
  -DCMAKE_C_COMPILER="$CROSS_CC" \
  -DCMAKE_CXX_COMPILER="$CROSS_CXX" \
  -DCMAKE_ASM_COMPILER="$CROSS_CC" \
  -DCMAKE_LINKER="$CROSS_LD" \
  -DCMAKE_OBJCOPY="$CROSS_OBJCOPY" \
  -DCMAKE_AR="$CROSS_AR" \
  -DCMAKE_STRIP="$CROSS_STRIP" \
  -DCMAKE_C_FLAGS="$CROSS_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CROSS_CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$CROSS_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$CROSS_LDFLAGS" \
  -Dprotobuf_BUILD_TESTS=OFF \
  -DABSL_PROPAGATE_CXX_STD=ON \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DPROTOC_PATH="$PROTOC"

log "Building"
ninja -C "$BUILD_DIR" -j"$JOBS"

# --- strip + stage ----------------------------------------------------------
log "Stripping host tools"
tools="aapt aapt2 aidl zipalign dexdump split-select \
       adb fastboot sqlite3 etc1tool hprof-conv e2fsdroid sload_f2fs mke2fs \
       make_f2fs make_f2fs_casefold dmtracedump \
       veridex"
for t in $tools; do
  [ -f "$BUILD_DIR/bin/$t" ] && "$CROSS_STRIP" "$BUILD_DIR/bin/$t" || true
done

mkdir -p "$OUT"
rm -rf "$OUT/bin-$TARGET"
cp -R "$BUILD_DIR/bin" "$OUT/bin-$TARGET"
log "Done -> $OUT/bin-$TARGET"
