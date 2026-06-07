# Prebuilt build image for the android-sdk-custom builds. Bakes the build tools
# and the zig / zig-as-llvm toolchain so CI only pulls (fast). zig drives the
# linux musl/gnu host-tool cross builds.
#
# All four platforms are wired: linux (zig), bionic (NDK clang, pulled at run
# time), windows (llvm-mingw) and macos (osxcross) — laid out like the sibling
# android-ndk-custom / llvm-custom images.
#
# The build scripts are NOT copied in — they are bind-mounted from the checkout
# at run time, so editing scripts/ needs no image rebuild.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e PLATFORM=linux -e TARGET=x86_64-linux-musl -e TAG=android-16.0.0_r4 \
#     ghcr.io/<owner>/sdk-builder \
#     bash -c 'scripts/fetch-source.sh && scripts/build.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.304+9787df942
ARG LLVM_MINGW_VERSION=20260505
ARG REPO_OWNER=HomuHomu833
ARG MACOS_SDK_VERSION=15.5

ENV DEBIAN_FRONTEND=noninteractive
# - build-essential/clang/lld: host compiler used to build the native protoc
#   that the cross build runs during code generation.
# - go/bison/flex/m4: required by several AOSP sources (selinux, e2fsprogs,
#   aidl, soong tooling).
# - autoconf/automake/libtool/autoconf-archive/pkg-config: autotools deps for
#   the bundled zlib/bzip2 + any source that regenerates configure.
# - jq: scripts/fetch-source.sh reads repos.json with it.
# - file/zip/unzip/xz-utils: SDK splice + archive steps.
# - openjdk-21-jre-headless: sdkmanager (make-sdk.sh) needs a JRE to fetch the
#   official build-tools/platform-tools that the built host tools are spliced into.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates aria2 xz-utils unzip zip p7zip-full git make cmake ninja-build \
        build-essential clang lld file tree jq openjdk-21-jre-headless \
        golang-go bison flex m4 python3 \
        autoconf automake libtool autoconf-archive pkg-config \
        zlib1g-dev libssl-dev libxml2-dev liblzma-dev libbz2-dev uuid-dev cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

# fetch: download with retries (transient GitHub 501/504 etc.), no dependence on
# aria2's --retry-on-unknown. build.sh defines an identical helper for standalone runs.
RUN printf '%s\n' '#!/bin/sh' \
    'i=0; until aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do' \
    '  i=$((i+1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; exit 1; }' \
    '  echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2' \
    'done' > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# zig (provides the cross C/C++ toolchain for the linux musl/gnu targets)
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

# zig-as-llvm: thin cc/c++/ar/strip/... wrappers around zig, keyed off $ZIG_TARGET.
# The wrappers `exec zig ...`, so zig must be on PATH (below) for the cross builds.
RUN if [ ! -f /opt/.no-zig ]; then \
        git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm; \
    fi

# zig on PATH so the zig-as-llvm wrappers resolve it.
ENV PATH="/opt/zig:${PATH}"

# bionic targets: the official NDK (clang + sysroot) is downloaded by build.sh at
#                 run time, so no image change is needed.

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
# llvm-mingw is intentionally NOT on PATH — build.sh calls it by absolute path, and
# keeping its windows-targeting clang off PATH avoids it shadowing the host clang
# used to build the native protoc.

# osxcross -> /opt/osxcross: the macOS cross toolchain (cctools-port: ld64/ar/
# ranlib/strip/lipo/... + clang wrappers) with the macOS SDK baked into
# /opt/osxcross/SDK. zig segfaults building macOS binaries, so darwin uses osxcross.
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

WORKDIR /work
