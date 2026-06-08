#!/usr/bin/env bash
# Cross-build the Android SDK host tools for one target. Driven entirely by env
# vars so it runs identically in CI and in `docker run`.
#
#   PLATFORM   linux | bionic   (see the per-PLATFORM case below)
#   TARGET     target triple, e.g. x86_64-linux-musl / aarch64-linux-gnu (linux)
#                                  aarch64-linux-android                  (bionic)
#   ARCH       CMAKE_SYSTEM_PROCESSOR (default: triple's arch field)
#   ROOTDIR    checkout root (default: cwd)
#   OUT        where the stripped host tools land (default: $ROOTDIR/out)
#   JOBS       parallelism (default: nproc)
#   NDK_VERSION   official NDK to pull for the bionic clang, e.g. 27 (bionic only)
#   NDK_REVISION  optional NDK revision letter, e.g. c (bionic only)
#   ANDROID_PLATFORM  bionic API level (default 25, riscv64 forced to 35; bionic only)
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

# Download with retries: re-run aria2c on any failure so transient GitHub 501/504
# (and the like) recover. Doesn't rely on aria2's --retry-on-unknown, which older
# aria2 builds don't have. Pass aria2c args, e.g. fetch --dir=/tmp -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

# --- toolchain selection ----------------------------------------------------
# Structured as a per-PLATFORM case: linux (zig), bionic (NDK clang), macos
# (osxcross), windows (llvm-mingw) — mirrors the sibling NDK/llvm repos.
CROSS_CMAKE_EXTRA=()   # extra -D flags a platform may need (e.g. macOS sysroot)
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
        # _GNU_SOURCE: AOSP/host code (and bundled deps like zstd's cover.c, which
        # calls qsort_r) assume GNU extensions that glibc hides behind it; musl
        # exposes them unconditionally, so this only matters for gnu.
        # strlcpy/strlcat shim: glibc only declares them from 2.38. Force-include
        # a shim that supplies them on older glibc instead of raising the
        # binaries' runtime glibc requirement. HAVE_STRLCPY/HAVE_STRLCAT make
        # deps that ship their own fallback (e.g. selinux's #ifndef HAVE_STRLCPY)
        # yield to the shim, avoiding a duplicate definition.
        CROSS_CFLAGS="-Wno-error=date-time -D_GNU_SOURCE -DHAVE_STRLCPY -DHAVE_STRLCAT -include $ROOTDIR/patches/misc/strl_compat.h"
        CROSS_LDFLAGS="-static-libstdc++ -static-libgcc" ;;
    esac
    # libpng ships SIMD code that doesn't build/link on every target: the 32-bit
    # Thumb encodings lack the Neon asm impl (undefined png_*_neon symbols), and
    # 32-bit/BE PowerPC lacks the VSX/AltiVec the intrinsics require. Disable the
    # relevant SIMD path so libpng falls back to portable C. (aarch64 Neon and
    # ppc64le VSX build fine and are left enabled.)
    case "$TARGET" in
      thumb-*|thumbeb-*)        CROSS_CFLAGS="$CROSS_CFLAGS -DPNG_ARM_NEON_OPT=0 -DOPENSSL_NO_ASM" ;;
      powerpc-*|powerpc64-*)    CROSS_CFLAGS="$CROSS_CFLAGS -DPNG_POWERPC_VSX_OPT=0" ;;
    esac
    # x32 ABI (x86_64 ISA, 32-bit pointers): clang emits initial-exec TLS with
    # 32-bit MOV/ADD, but lld's R_X86_64_GOTTPOFF relaxation requires a 64-bit
    # MOVQ/ADDQ, so the link fails. These are fully-static executables, so force
    # local-exec TLS (no GOTTPOFF) which is the correct model here anyway.
    case "$TARGET" in
      *x32) CROSS_CFLAGS="$CROSS_CFLAGS -ftls-model=local-exec" ;;
    esac
    ;;
  bionic)
    # Android host tools built against bionic with the official NDK's clang, so the
    # binaries run on-device. The NDK ships its own sysroot + libc, so none of the
    # musl/glibc LFS juggling from the linux case applies. SYSTEM_NAME stays Linux
    # (not Android) so CMake just uses the clang we point it at instead of taking
    # over with its own NDK toolchain machinery — mirrors the sibling NDK repo.
    : "${NDK_VERSION:?set NDK_VERSION for the bionic build}"
    NDK_REVISION="${NDK_REVISION:-}"
    API="${ANDROID_PLATFORM:-25}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    if [ "$API" -lt 25 ]; then
      echo "bionic build requires ANDROID_PLATFORM >= 25 (got $API)." >&2
      exit 1
    fi
    NDK_NAME="android-ndk-r${NDK_VERSION}${NDK_REVISION}"
    NDK_DIR="$ROOTDIR/$NDK_NAME"
    if [ ! -d "$NDK_DIR" ]; then
      log "Downloading official NDK ($NDK_NAME)"
      fetch --dir="$ROOTDIR" -o ndk.zip "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip"
      unzip -qq "$ROOTDIR/ndk.zip" -d "$ROOTDIR"
      rm -f "$ROOTDIR/ndk.zip"
    fi
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CROSS_CC="$TC/bin/${TARGET}${API}-clang"; CROSS_CXX="${CROSS_CC}++"
    CROSS_LD="$TC/bin/ld"; CROSS_AR="$TC/bin/llvm-ar"; CROSS_RANLIB="$TC/bin/llvm-ranlib"
    CROSS_STRIP="$TC/bin/llvm-strip"; CROSS_OBJCOPY="$TC/bin/llvm-objcopy"
    SYSTEM_NAME=Linux
    # reallocarray() is API 29+ in bionic but selinux is built -DHAVE_REALLOCARRAY;
    # force-include a shim that supplies it on the lower API levels we target.
    CROSS_CFLAGS="-Wno-error=date-time -fno-sanitize=undefined -include $ROOTDIR/patches/misc/host_compat.h"
    CROSS_LDFLAGS="-static-libstdc++ -static-libgcc"
    ;;
  macos)
    # macOS host tools via osxcross (cctools-port + clang wrappers that carry the
    # macOS SDK sysroot). zig segfaults building macOS binaries, so darwin uses
    # osxcross — mirrors the sibling NDK/llvm repos.
    TC=/opt/osxcross
    export PATH="$TC/bin:$PATH"
    case "$TARGET" in
      arm64e-*)          OSX_ARCH=arm64e ;;   # distinct PAC ABI, not arm64
      aarch64-*|arm64-*) OSX_ARCH=arm64 ;;
      x86_64h-*)         OSX_ARCH=x86_64h ;;  # Haswell+ x86_64 slice
      x86_64-*)          OSX_ARCH=x86_64 ;;
      *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
    esac
    # osxcross names wrappers with the SDK's darwin version (e.g.
    # arm64-apple-darwin24.5-clang); resolve the prefix by globbing.
    CCWRAP="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $OSX_ARCH not found in $TC/bin" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    CROSS_CC="$TC/bin/${HOST}-clang"; CROSS_CXX="$TC/bin/${HOST}-clang++"
    CROSS_LD="$TC/bin/${HOST}-ld"; CROSS_AR="$TC/bin/${HOST}-ar"
    CROSS_RANLIB="$TC/bin/${HOST}-ranlib"; CROSS_STRIP="$TC/bin/${HOST}-strip"
    CROSS_OBJCOPY=""                  # cctools ships no objcopy; nothing here needs it
    SYSTEM_NAME=Darwin
    CROSS_CFLAGS="-Wno-error=date-time -D_DARWIN_C_SOURCE -include $ROOTDIR/patches/misc/host_compat.h"
    CROSS_LDFLAGS=""
    # Point CMake's Apple support at the osxcross SDK + pin arch/deployment target.
    SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
    CROSS_CMAKE_EXTRA=(-DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
    [ -n "$SDKROOT" ] && CROSS_CMAKE_EXTRA+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
    # cctools libtool under the plain `libtool` name on PATH, in case any archive
    # merge step shells out to it (parity with the sibling repos).
    LIBTOOLBIN="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-libtool 2>/dev/null | head -n1 || true)"
    if [ -n "$LIBTOOLBIN" ]; then
      mkdir -p "$BUILD_DIR/.macos-shims"; ln -sf "$LIBTOOLBIN" "$BUILD_DIR/.macos-shims/libtool"
      export PATH="$BUILD_DIR/.macos-shims:$PATH"
    fi
    ;;
  windows)
    # Windows host tools via llvm-mingw (clang + lld targeting ucrt mingw-w64).
    TC=/opt/llvm-mingw
    CROSS_CC="$TC/bin/${TARGET}-clang"; CROSS_CXX="$TC/bin/${TARGET}-clang++"
    CROSS_LD="$TC/bin/${TARGET}-ld"; CROSS_AR="$TC/bin/${TARGET}-ar"
    CROSS_RANLIB="$TC/bin/${TARGET}-ranlib"; CROSS_STRIP="$TC/bin/${TARGET}-strip"
    CROSS_OBJCOPY="$TC/bin/${TARGET}-objcopy"
    SYSTEM_NAME=Windows
    CROSS_CFLAGS="-Wno-error=date-time -include $ROOTDIR/patches/misc/host_compat.h"
    # Static CRT/libstdc++ so the .exe tools run without shipping the mingw runtime DLLs.
    CROSS_LDFLAGS="-static -static-libstdc++ -static-libgcc"
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

# --- extra deps (zlib + bzip2, static archives, cross-compiled for target) --
# We only consume the static .a archives, so -static is only meaningful for the
# tools' throwaway test binaries. Pass it for musl (proven path); never for gnu,
# since zig refuses to statically link glibc ("libc ... requires dynamic linking").
case "$TARGET" in
  *musl*) DEP_STATIC="-static" ;;
  *)      DEP_STATIC="" ;;
esac
mkdir -p "$EXTRA_PREFIX"
if [ ! -f "$EXTRA_PREFIX/lib/libz.a" ]; then
  log "Building zlib (static, $TARGET)"
  ( cd "$ROOTDIR"
    fetch --dir=/tmp -o zlib-1.3.1.tar.xz https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz && xz -d < /tmp/zlib-1.3.1.tar.xz | tar -x && rm /tmp/zlib-1.3.1.tar.xz
    cd zlib-1.3.1
    CC="$CROSS_CC" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" ./configure --prefix="$EXTRA_PREFIX" --static
    make -j"$JOBS" install )
fi
if [ ! -f "$EXTRA_PREFIX/lib/libbz2.a" ]; then
  log "Building bzip2 (static, $TARGET)"
  ( cd "$ROOTDIR"
    fetch --dir=/tmp -o bzip2-1.0.8.tar.gz https://www.sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz && gzip -d < /tmp/bzip2-1.0.8.tar.gz | tar -x && rm /tmp/bzip2-1.0.8.tar.gz
    cd bzip2-1.0.8
    make CC="$CROSS_CC" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" CFLAGS="$DEP_STATIC" LDFLAGS="$DEP_STATIC" libbz2.a
    cp -f libbz2.a "$EXTRA_PREFIX/lib/"
    cp -f bzlib.h "$EXTRA_PREFIX/include/" )
fi

# --- the SDK host tools -----------------------------------------------------
# TARGET_OS maps our PLATFORM to the AOSP Android.bp os axis (android | linux |
# darwin | windows), so the module CMake files can do the same per-OS source/flag
# selection the .bp files do. (bionic builds set CMAKE_SYSTEM_NAME=Linux, so this
# is the only way CMake can tell android apart from a Linux host.)
case "$PLATFORM" in
  bionic)  TARGET_OS=android ;;
  macos)   TARGET_OS=darwin ;;
  windows) TARGET_OS=windows ;;
  *)       TARGET_OS=linux ;;
esac

log "Configuring SDK ($PLATFORM / $TARGET)"
cmake -GNinja \
  -B "$BUILD_DIR" \
  -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
  -DTARGET_OS="$TARGET_OS" \
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
  -DPROTOC_PATH="$PROTOC" \
  "${CROSS_CMAKE_EXTRA[@]}"

log "Building"
ninja -C "$BUILD_DIR" -j"$JOBS"

# --- strip + stage ----------------------------------------------------------
log "Stripping host tools"
tools="aapt aapt2 aidl zipalign dexdump split-select \
       adb fastboot sqlite3 etc1tool hprof-conv e2fsdroid sload_f2fs mke2fs \
       make_f2fs make_f2fs_casefold dmtracedump \
       veridex"
for t in $tools; do
  # windows tools are $t.exe; everything else is bare $t
  for f in "$BUILD_DIR/bin/$t" "$BUILD_DIR/bin/$t.exe"; do
    [ -f "$f" ] && "$CROSS_STRIP" "$f" || true
  done
done

mkdir -p "$OUT"
rm -rf "$OUT/bin-$TARGET"
cp -R "$BUILD_DIR/bin" "$OUT/bin-$TARGET"
log "Done -> $OUT/bin-$TARGET"
