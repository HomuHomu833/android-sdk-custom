# Prebuilt build image for the android-sdk-custom builds. Bakes the build tools
# and the zig / zig-as-llvm toolchain so CI only pulls (fast). zig drives the
# linux musl/gnu host-tool cross builds.
#
# The linux and bionic platforms are wired up today (bionic pulls the official
# NDK clang at run time, so it needs no baked-in toolchain). The image is laid
# out like the sibling android-ndk-custom / llvm-custom images so the windows
# (llvm-mingw) and macos (osxcross) toolchains can be dropped in later without
# reshaping anything — see the "FUTURE" markers below.
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
ARG REPO_OWNER=HomuHomu833

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
        ca-certificates aria2 xz-utils unzip zip git make cmake ninja-build \
        build-essential clang lld file tree jq openjdk-21-jre-headless \
        golang-go bison flex m4 \
        autoconf automake libtool autoconf-archive pkg-config \
        zlib1g-dev libssl-dev libxml2-dev liblzma-dev libbz2-dev uuid-dev cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

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
#                 run time, so no image change is needed — only aria2/unzip, which
#                 are already installed above.
# FUTURE: windows targets — install llvm-mingw under /opt/llvm-mingw here.
# FUTURE: macos targets   — build osxcross under /opt/osxcross here.

WORKDIR /work
