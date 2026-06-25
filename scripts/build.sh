#!/usr/bin/env bash
# Cross-build the Android SDK host tools for one target. All inputs are env vars
# so CI and `docker run` behave identically. Run fetch-source.sh first.
#
#   PLATFORM   linux | bionic | macos | windows | bsd
#   TARGET     target triple (e.g. x86_64-linux-musl, aarch64-linux-android,
#              aarch64-freebsd-none, arm-openbsd-eabi)
#   ARCH       CMAKE_SYSTEM_PROCESSOR (default: triple's arch field)
#   ROOTDIR    checkout root (default: cwd)
#   OUT        stripped host tools land here (default: $ROOTDIR/out)
#   JOBS       parallelism (default: nproc)
#   NDK_VERSION/NDK_REVISION  official NDK for the bionic clang (bionic only)
#   ANDROID_PLATFORM  bionic API level (default 25, riscv64 forced 35; bionic only)
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

# Re-run aria2c on any failure so transient GitHub 5xx recover (older aria2 lacks
# --retry-on-unknown). Args pass through, e.g. fetch --dir=/tmp -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

# --- toolchain selection (per-PLATFORM: linux/bsd zig, bionic NDK clang, macos
# osxcross, windows llvm-mingw) ----------------------------------------------
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
    # musl: fully static, needs the LFS aliases + ANDROID_HOST_MUSL the AOSP
    # sources key off. glibc: ships LFS natively, links dynamically.
    case "$TARGET" in
      *musl*)
        # host_compat.h supplies GNU/bionic-isms musl omits (e.g.
        # TEMP_FAILURE_RETRY); its reallocarray fallback is gated off for musl.
        CROSS_CFLAGS="-Wno-error=date-time -include $ROOTDIR/patches/misc/host_compat.h -Doff64_t=off_t -Dmmap64=mmap -Dlseek64=lseek -Dpread64=pread -Dpwrite64=pwrite -Dftruncate64=ftruncate -DANDROID_HOST_MUSL -static"
        CROSS_LDFLAGS="-static" ;;
      *)
        # strlcpy/strlcat: glibc declares them only from 2.38, so force-include a
        # shim rather than raise the runtime glibc floor. HAVE_STRLCPY/HAVE_STRLCAT
        # make deps with their own fallback (e.g. selinux) yield to it.
        CROSS_CFLAGS="-Wno-error=date-time -D_GNU_SOURCE=1 -DHAVE_STRLCPY -DHAVE_STRLCAT -include $ROOTDIR/patches/misc/strl_compat.h"
        CROSS_LDFLAGS="-static-libstdc++ -static-libgcc" ;;
    esac
    # libpng SIMD doesn't build on every target: 32-bit Thumb lacks the Neon asm
    # (undefined png_*_neon), 32-bit/BE PowerPC lacks VSX/AltiVec. Fall back to C
    # (aarch64 Neon and ppc64le VSX stay on). PowerPC uses libpng's
    # PNG_POWERPC_VSX=off; a global -DPNG_POWERPC_VSX_OPT=0 would clash with
    # libpng's own -D...=2 (-Wmacro-redefined). Thumb keeps the global -D (libpng's
    # arch regex ignores "thumb", so nothing collides).
    case "$TARGET" in
      thumb-*|thumbeb-*)
        CROSS_CFLAGS="$CROSS_CFLAGS -DPNG_ARM_NEON_OPT=0 -DOPENSSL_NO_ASM"
        CROSS_CMAKE_EXTRA+=(-DOPENSSL_NO_ASM=ON) ;;
      powerpc-*|powerpc64-*)    CROSS_CMAKE_EXTRA+=(-DPNG_POWERPC_VSX=off) ;;
    esac
    # mips64 LP64 (n64 ABI): pre-empt asm-generic/int-l64.h, which defines
    # __s64/__u64 as 'long', to avoid redefinition conflicts with e2fsprogs and
    # other code that expects 'long long'. See patches/misc/mips64-int-ll64.h.
    case "$TARGET" in
      mips64-*gnuabi64|mips64el-*gnuabi64)
        CROSS_CFLAGS="$CROSS_CFLAGS -include $ROOTDIR/patches/misc/mips64-int-ll64.h" ;;
    esac
    # x32: force local-exec TLS. lld can't relax R_X86_64_GOTTPOFF to clang's
    # 32-bit initial-exec sequence (link fails); these are static, so local-exec fits.
    case "$TARGET" in
      *x32) CROSS_CFLAGS="$CROSS_CFLAGS -ftls-model=local-exec" ;;
    esac
    ;;
  bionic)
    # Android host tools against bionic via the official NDK clang, so they run
    # on-device. NDK ships its own sysroot, so no musl/glibc LFS juggling.
    # SYSTEM_NAME stays Linux so CMake uses our clang, not its NDK machinery.
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
    # reallocarray is API 29+ in bionic but selinux builds -DHAVE_REALLOCARRAY;
    # force-include a shim that supplies it on the lower API levels.
    CROSS_CFLAGS="-Wno-error=date-time -fno-sanitize=undefined -include $ROOTDIR/patches/misc/host_compat.h"
    CROSS_LDFLAGS="-static-libstdc++ -static-libgcc"
    # termux-usb shim: always built into the bionic adb/fastboot, inert until the
    # user sets LIBUSB_TERMUX_IMPL=1 at runtime (lets non-rooted Termux users get
    # USB FDs from termux-usb). libtermuxadb.a's libusb_* refs resolve against our
    # libusb at link. See patches/termux/.
    case "$TARGET" in
      aarch64-linux-android)    RUST_TARGET=aarch64-linux-android ;;
      armv7a-linux-androideabi) RUST_TARGET=armv7-linux-androideabi ;;
      i686-linux-android)       RUST_TARGET=i686-linux-android ;;
      x86_64-linux-android)     RUST_TARGET=x86_64-linux-android ;;
      *)                        RUST_TARGET="" ;;   # e.g. riscv64: no shim
    esac
    if [ -n "$RUST_TARGET" ]; then
      # CARGO_HOME must be writable (the image installs Rust read-only under /opt);
      # the staticlib needs no target linker, but set one defensively for cargo.
      export CARGO_HOME="${CARGO_HOME:-$ROOTDIR/.cargo}"
      export "CARGO_TARGET_$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_')_LINKER=$CROSS_CC"
      log "Building libtermuxadb ($RUST_TARGET)"
      ( cd "$ROOTDIR/patches/termux/libtermuxadb" && cargo build --release --target "$RUST_TARGET" )
      TERMUXADB_A="$ROOTDIR/patches/termux/libtermuxadb/target/$RUST_TARGET/release/libtermuxadb.a"
      [ -f "$TERMUXADB_A" ] || { echo "termux shim: $TERMUXADB_A not built" >&2; exit 1; }
      CROSS_CMAKE_EXTRA+=(-DTERMUX_USB_SHIM=ON "-DTERMUXADB_LIB=$TERMUXADB_A")
    fi
    ;;
  bsd)
    # BSD host tools via zig-as-llvm (same wrappers as linux), all BSD targets.
    TC=/opt/zig-as-llvm
    export ZIG_TARGET="$TARGET"
    [ -d "$ROOTDIR/patches/musl/zig" ] && cp -R "$ROOTDIR/patches/musl/zig/." /opt/zig/ || true
    CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_LD="$TC/bin/ld"
    CROSS_AR="$TC/bin/ar"; CROSS_RANLIB="$TC/bin/ranlib"
    CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"
    case "$(echo "$TARGET" | cut -d- -f2)" in
      freebsd) SYSTEM_NAME=FreeBSD ;;
      netbsd)  SYSTEM_NAME=NetBSD ;;
      openbsd) SYSTEM_NAME=OpenBSD ;;
    esac
    # host_compat.h supplies glibc/bionic-isms BSDs omit (TEMP_FAILURE_RETRY,
    # reallocarray); Windows/Darwin sections stay inert. BSD links dynamically.
    CROSS_CFLAGS="-Wno-error=date-time -include $ROOTDIR/patches/misc/host_compat.h -isystem $ROOTDIR/patches/bsd-compat"
    CROSS_LDFLAGS="-static-libstdc++ -static-libgcc"
    # Per-arch SIMD/TLS, same as linux (see there for the PNG_POWERPC_VSX why).
    case "$TARGET" in
      thumb-*|thumbeb-*)
        CROSS_CFLAGS="$CROSS_CFLAGS -DPNG_ARM_NEON_OPT=0 -DOPENSSL_NO_ASM"
        CROSS_CMAKE_EXTRA+=(-DOPENSSL_NO_ASM=ON) ;;
      powerpc-*|powerpc64-*)    CROSS_CMAKE_EXTRA+=(-DPNG_POWERPC_VSX=off) ;;
    esac
    case "$TARGET" in
      *x32) CROSS_CFLAGS="$CROSS_CFLAGS -ftls-model=local-exec" ;;
    esac
    ;;
  macos)
    # macOS host tools via osxcross (cctools-port + clang wrappers carrying the
    # SDK sysroot); zig segfaults building Darwin binaries.
    TC=/opt/osxcross
    export PATH="$TC/bin:$PATH"
    case "$TARGET" in
      arm64e-*)          OSX_ARCH=arm64e ;;   # distinct PAC ABI, not arm64
      aarch64-*|arm64-*) OSX_ARCH=arm64 ;;
      x86_64h-*)         OSX_ARCH=x86_64h ;;  # Haswell+ x86_64 slice
      x86_64-*)          OSX_ARCH=x86_64 ;;
      *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
    esac
    # osxcross wrappers carry the SDK's darwin version (e.g.
    # arm64-apple-darwin24.5-clang); resolve the prefix by globbing.
    CCWRAP="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $OSX_ARCH not found in $TC/bin" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    CROSS_CC="$TC/bin/${HOST}-clang"; CROSS_CXX="$TC/bin/${HOST}-clang++"
    CROSS_LD="$TC/bin/${HOST}-ld"; CROSS_AR="$TC/bin/${HOST}-ar"
    CROSS_RANLIB="$TC/bin/${HOST}-ranlib"; CROSS_STRIP="$TC/bin/${HOST}-strip"
    CROSS_OBJCOPY=""                  # cctools ships no objcopy; nothing here needs it
    SYSTEM_NAME=Darwin
    CROSS_CFLAGS="-Wno-error=date-time -include $ROOTDIR/patches/misc/host_compat.h -D_LIBCPP_DISABLE_AVAILABILITY"
    CROSS_LDFLAGS=""
    # Point CMake's Apple support at the osxcross SDK + pin arch/deployment target.
    SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
    CROSS_CMAKE_EXTRA=(-DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
    [ -n "$SDKROOT" ] && CROSS_CMAKE_EXTRA+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
    # cctools libtool under the plain `libtool` name, in case a step shells out to it.
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
    # Static libstdc++/libgcc + whole-archive libwinpthread so the .exe tools need
    # no mingw DLLs. --whole-archive keeps winpthread's TLS/thread-exit callbacks a
    # plain -lwinpthread would drop; -Bdynamic restores linkage for ucrt/system libs.
    CROSS_LDFLAGS="-static-libstdc++ -static-libgcc -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive,-Bdynamic"
    ;;
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac
export CROSS_CC CROSS_CXX CROSS_LD CROSS_AR CROSS_RANLIB CROSS_STRIP CROSS_OBJCOPY CROSS_LDFLAGS

ADBMDNS_RUST_TARGET=""
case "$PLATFORM" in
  bionic)
    case "$TARGET" in
      aarch64-linux-android)    ADBMDNS_RUST_TARGET=aarch64-linux-android ;;
      armv7a-linux-androideabi) ADBMDNS_RUST_TARGET=armv7-linux-androideabi ;;
      i686-linux-android)       ADBMDNS_RUST_TARGET=i686-linux-android ;;
      x86_64-linux-android)     ADBMDNS_RUST_TARGET=x86_64-linux-android ;;
    esac ;;
  macos)
    case "$TARGET" in
      x86_64-*|x86_64h-*)          ADBMDNS_RUST_TARGET=x86_64-apple-darwin ;;
      arm64-*|arm64e-*|aarch64-*)  ADBMDNS_RUST_TARGET=aarch64-apple-darwin ;;
    esac ;;
  windows)
    case "$TARGET" in
      x86_64-w64-mingw32)  ADBMDNS_RUST_TARGET=x86_64-pc-windows-gnu ;;
      i686-w64-mingw32)    ADBMDNS_RUST_TARGET=i686-pc-windows-gnu ;;
      aarch64-w64-mingw32) ADBMDNS_RUST_TARGET=aarch64-pc-windows-gnullvm ;;
    esac ;;
  linux)
    case "$TARGET" in
      x86_64-linux-gnu)       ADBMDNS_RUST_TARGET=x86_64-unknown-linux-gnu ;;
      x86_64-linux-musl)      ADBMDNS_RUST_TARGET=x86_64-unknown-linux-musl ;;
      aarch64-linux-gnu)      ADBMDNS_RUST_TARGET=aarch64-unknown-linux-gnu ;;
      aarch64-linux-musl)     ADBMDNS_RUST_TARGET=aarch64-unknown-linux-musl ;;
      x86-linux-gnu)          ADBMDNS_RUST_TARGET=i686-unknown-linux-gnu ;;
      x86-linux-musl)         ADBMDNS_RUST_TARGET=i686-unknown-linux-musl ;;
      riscv64-linux-gnu)      ADBMDNS_RUST_TARGET=riscv64gc-unknown-linux-gnu ;;
      riscv64-linux-musl)     ADBMDNS_RUST_TARGET=riscv64gc-unknown-linux-musl ;;
      s390x-linux-gnu)        ADBMDNS_RUST_TARGET=s390x-unknown-linux-gnu ;;
      powerpc64le-linux-musl) ADBMDNS_RUST_TARGET=powerpc64le-unknown-linux-musl ;;
      loongarch64-linux-gnu)  ADBMDNS_RUST_TARGET=loongarch64-unknown-linux-gnu ;;
      loongarch64-linux-musl) ADBMDNS_RUST_TARGET=loongarch64-unknown-linux-musl ;;
      arm-linux-gnueabi)      ADBMDNS_RUST_TARGET=arm-unknown-linux-gnueabi ;;
      arm-linux-gnueabihf)    ADBMDNS_RUST_TARGET=arm-unknown-linux-gnueabihf ;;
      arm-linux-musleabi)     ADBMDNS_RUST_TARGET=arm-unknown-linux-musleabi ;;
      arm-linux-musleabihf)   ADBMDNS_RUST_TARGET=arm-unknown-linux-musleabihf ;;
    esac ;;
  bsd)
    case "$TARGET" in
      x86_64-freebsd-none) ADBMDNS_RUST_TARGET=x86_64-unknown-freebsd ;;
      x86_64-netbsd-none)  ADBMDNS_RUST_TARGET=x86_64-unknown-netbsd ;;
      x86-freebsd-none)    ADBMDNS_RUST_TARGET=i686-unknown-freebsd ;;
    esac ;;
esac

if [ -n "$ADBMDNS_RUST_TARGET" ]; then
  RUST_SYSROOT="$(rustc --print sysroot 2>/dev/null || echo /opt/rust)"
  if [ ! -d "$RUST_SYSROOT/lib/rustlib/$ADBMDNS_RUST_TARGET" ]; then
    log "adb mDNS: rust-std for $ADBMDNS_RUST_TARGET not installed -> openscreen fallback"
    ADBMDNS_RUST_TARGET=""
  fi
fi

if [ -n "$ADBMDNS_RUST_TARGET" ]; then
  export CARGO_HOME="${CARGO_HOME:-$ROOTDIR/.cargo}"
  export "CARGO_TARGET_$(echo "$ADBMDNS_RUST_TARGET" | tr 'a-z-' 'A-Z_')_LINKER=$CROSS_CC"
  MDNS_CRATE="$ROOTDIR/src/adb/client/adbmdns"
  log "Building adb mDNS bridge / libzeroconf ($ADBMDNS_RUST_TARGET)"
  ( cd "$MDNS_CRATE" && cargo rustc --release --target "$ADBMDNS_RUST_TARGET" --crate-type staticlib )
  ADBMDNS_A="$MDNS_CRATE/target/$ADBMDNS_RUST_TARGET/release/libzeroconf.a"
  [ -f "$ADBMDNS_A" ] || { echo "adb mDNS bridge: $ADBMDNS_A not built" >&2; exit 1; }
  CROSS_CMAKE_EXTRA+=(-DHAVE_RUST_MDNS=ON "-DADBMDNS_LIB=$ADBMDNS_A")
else
  log "adb mDNS: no Rust std for $TARGET -> openscreen fallback"
  CROSS_CMAKE_EXTRA+=(-DHAVE_RUST_MDNS=OFF)
fi

# --- native protoc: built with the host compiler (not the cross toolchain),
# since the cross build invokes it at codegen time ---------------------------
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

# --- extra deps: zlib + bzip2 static archives, cross-compiled. -static only
# affects the throwaway test binaries; pass it for musl only (zig refuses to
# statically link glibc/bsd libc) ------------------------------------------------
case "$TARGET" in
  *musl*) DEP_STATIC="-static" ;;
  *)      DEP_STATIC="" ;;
esac
mkdir -p "$EXTRA_PREFIX"
if [ ! -f "$EXTRA_PREFIX/lib/libz.a" ]; then
  log "Building zlib (static, $TARGET)"
  # MIPS with -mabicalls (glibc default) requires PIC; without -fPIC clang emits a
  # warning to stderr that makes zlib's configure think the compiler is "too harsh".
  # -fno-sanitize=undefined: zig may instrument C code with UBSan by default;
  # libz.a is a pre-built static archive, so the ubsan runtime isn't linked in
  # at final link time, causing undefined __ubsan_handle_* symbol errors.
  case "$TARGET" in
    mips*|mipsel*) ZLIB_CFLAGS="-fPIC -fno-sanitize=undefined" ;;
    *)             ZLIB_CFLAGS="-fno-sanitize=undefined" ;;
  esac
  ( cd "$ROOTDIR"
    fetch --dir=/tmp -o zlib-1.3.1.tar.xz https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz && xz -d < /tmp/zlib-1.3.1.tar.xz | tar -x && rm /tmp/zlib-1.3.1.tar.xz
    cd zlib-1.3.1
    CC="$CROSS_CC" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" CFLAGS="$ZLIB_CFLAGS" ./configure --prefix="$EXTRA_PREFIX" --static
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
# TARGET_OS maps PLATFORM to the AOSP Android.bp os axis so module CMake files do
# the same per-OS selection. (bionic sets CMAKE_SYSTEM_NAME=Linux, so this is the
# only way CMake distinguishes android from a Linux host.)
case "$PLATFORM" in
  bionic)  TARGET_OS=android ;;
  macos)   TARGET_OS=darwin ;;
  windows) TARGET_OS=windows ;;
  bsd)     TARGET_OS=bsd ;;
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
