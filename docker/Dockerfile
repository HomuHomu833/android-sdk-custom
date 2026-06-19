# Prebuilt build image for the android-sdk-custom builds: bakes the build tools
# and toolchains so CI only pulls. All five platforms: linux/bsd (zig), bionic
# (NDK clang, pulled at run time), windows (llvm-mingw), macos (osxcross).
#
# Build scripts are NOT copied in — they're bind-mounted from the checkout at run
# time, so editing scripts/ needs no rebuild.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e PLATFORM=linux -e TARGET=x86_64-linux-musl -e TAG=android-17.0.0_r1 \
#     ghcr.io/<owner>/sdk-builder \
#     bash -c 'scripts/fetch-source.sh && scripts/build.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.857+2b2b85c5f
ARG LLVM_MINGW_VERSION=20260505
ARG REPO_OWNER=HomuHomu833
ARG MACOS_SDK_VERSION=15.5

ENV DEBIAN_FRONTEND=noninteractive
# - build-essential/clang/lld: host compiler for the native protoc the cross
#   build runs at codegen.
# - go/bison/flex/m4: needed by selinux, e2fsprogs, aidl, soong tooling.
# - autoconf/automake/libtool/autoconf-archive/pkg-config: autotools deps for the
#   bundled zlib/bzip2 and sources that regenerate configure.
# - jq: fetch-source.sh reads repos.json. file/zip/unzip/xz: splice + archive.
# - openjdk-21-jre-headless: sdkmanager needs a JRE to fetch the official SDK.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates aria2 xz-utils unzip zip p7zip-full git make cmake ninja-build \
        build-essential clang lld file tree jq openjdk-21-jre-headless \
        golang-go bison flex m4 python3 \
        autoconf automake libtool autoconf-archive pkg-config \
        zlib1g-dev libssl-dev libxml2-dev liblzma-dev libbz2-dev uuid-dev cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

# fetch: aria2c with retries (transient GitHub 5xx), no --retry-on-unknown
# dependence. build.sh defines an identical helper for standalone runs.
RUN printf '%s\n' '#!/bin/sh' \
    'i=0; until aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do' \
    '  i=$((i+1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; exit 1; }' \
    '  echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2' \
    'done' > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# zig: cross C/C++ toolchain for the linux musl/gnu and bsd targets.
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)        zig_arch="x86_64" ;; \
        aarch64)       zig_arch="aarch64" ;; \
        armv7l|armv8l) zig_arch="arm" ;; \
        riscv64)       zig_arch="riscv64" ;; \
        ppc64le)       zig_arch="powerpc64le" ;; \
        i686|i386)     zig_arch="x86" ;; \
        loongarch64)   zig_arch="loongarch64" ;; \
        s390x)         zig_arch="s390x" ;; \
        *) echo "WARNING: unsupported zig host arch '$arch'; skipping zig and zig-as-llvm"; touch /opt/.no-zig ;; \
    esac; \
    if [ ! -f /opt/.no-zig ]; then \
        case "$ZIG_VERSION" in \
            *dev*) zig_base="https://ziglang.org/builds" ;;        \
            *)     zig_base="https://ziglang.org/download/${ZIG_VERSION}" ;; \
        esac; \
        ( i=0; until aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o zig.tar.xz \
            "${zig_base}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
          do i=$((i+1)); [ "$i" -ge 5 ] && exit 1; echo "aria2c retry $i/5" >&2; sleep 2; done ) \
        && tar -xJf /tmp/zig.tar.xz -C /opt \
        && rm /tmp/zig.tar.xz \
        && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
        && chmod -R a+w /opt/zig/lib; \
    fi   # build.sh overlays patches/zig here at run time (non-root)

# zig-as-llvm: thin cc/c++/ar/strip/... wrappers around zig (keyed off
# $ZIG_TARGET); they `exec zig`, so zig must be on PATH (below).
RUN if [ ! -f /opt/.no-zig ]; then \
        git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm; \
    fi

# zig on PATH so the zig-as-llvm wrappers resolve it.
ENV PATH="/opt/zig:${PATH}"

# bionic: build.sh downloads the official NDK (clang + sysroot) at run time.

# llvm-mingw (windows targets; only x86_64 / aarch64 linux hosts can run it)
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) \
            fetch --dir=/tmp -o llvm-mingw.tar.xz \
                "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}.tar.xz" \
            && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt \
            && rm /tmp/llvm-mingw.tar.xz \
            && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}" /opt/llvm-mingw ;; \
        *) echo "WARNING: llvm-mingw does not support host arch '$arch'; Windows cross-builds will be unavailable" ;; \
    esac
# Intentionally NOT on PATH — build.sh calls it by absolute path; keeping its
# windows clang off PATH avoids shadowing the host clang used for native protoc.

# osxcross: macOS cross toolchain (cctools-port + clang wrappers) with the macOS
# SDK baked into /opt/osxcross/SDK; zig segfaults building Darwin binaries.
ARG OSXCROSS_REF=master
RUN git clone https://github.com/tpoechtrager/osxcross /tmp/osxcross \
    && git -C /tmp/osxcross checkout "$OSXCROSS_REF" \
    && fetch \
        --dir=/tmp/osxcross/tarballs -o "MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
        "https://github.com/joseluisq/macosx-sdks/releases/download/${MACOS_SDK_VERSION}/MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
    && cd /tmp/osxcross \
    && UNATTENDED=1 ENABLE_ARCHS="x86_64 x86_64h arm64 arm64e" OSX_VERSION_MIN=11.0 \
       TARGET_DIR=/opt/osxcross ./build.sh \
    && cd / \
    && rm -rf /tmp/osxcross

# Rust (termux-usb shim): builds libtermuxadb.a for the bionic adb/fastboot. As a
# staticlib (libusb1-sys link feature off) it needs no C cross-compile/NDK linker,
# just std for the android targets. Installed from the standalone dist tarballs via
# the aria2c fetch helper (rustup-init needs curl/wget, absent here), read-only
# under /opt/rust; build.sh uses a writable CARGO_HOME. Host x86_64 (the CI runner).
ARG RUST_VERSION=1.84.0
RUN set -eu; \
    base="https://static.rust-lang.org/dist"; \
    fetch --dir=/tmp -o rust.tar.xz "$base/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.xz"; \
    mkdir -p /tmp/rust && tar -xJf /tmp/rust.tar.xz -C /tmp/rust --strip-components=1; \
    /tmp/rust/install.sh --prefix=/opt/rust --disable-ldconfig --without=rust-docs; \
    rm -rf /tmp/rust /tmp/rust.tar.xz; \
    for t in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do \
        fetch --dir=/tmp -o "std.tar.xz" "$base/rust-std-${RUST_VERSION}-$t.tar.xz"; \
        mkdir -p /tmp/std && tar -xJf /tmp/std.tar.xz -C /tmp/std --strip-components=1; \
        /tmp/std/install.sh --prefix=/opt/rust --disable-ldconfig; \
        rm -rf /tmp/std /tmp/std.tar.xz; \
    done; \
    chmod -R a+rX /opt/rust
ENV PATH="/opt/rust/bin:${PATH}"

WORKDIR /work
