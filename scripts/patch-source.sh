#!/usr/bin/env bash
# Best-effort source fixups for the non-Soong toolchains, run on every release:
# a fixup a release doesn't need is reported and skipped. What gets compiled
# is builder/overlay's business; new files live in patches/sources/.
# Env: ROOTDIR, TARGET (only the per-target sections read it), TAG.
set -Euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
TARGET="${TARGET:-}"
TAG="${TAG:-}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Fixups a release doesn't need are expected; note their lines for one summary.
SKIPPED=""
trap 'SKIPPED="$SKIPPED $LINENO"' ERR

# Older releases keep these in system/core: adb and liblog (platform-tools
# 30.x and earlier), libbase (30.0.1 and earlier), libziparchive (29.x).
# Fixups name them through these; the Python blocks read them from the env.
pick() { if [ -d "$1" ]; then echo "$1"; else echo "$2"; fi; }
ADB="$(pick src/adb src/core/adb)"
LIBBASE="$(pick src/libbase src/core/base)"
LIBLOG="$(pick src/logging/liblog src/core/liblog)"
ZIPARCHIVE="$(pick src/libziparchive src/core/libziparchive)"
export ADB LIBBASE

# A unified diff against the checkout (paths src/...); forward only, no .rej.
apply() { patch -p1 -N -s -t -r - --no-backup-if-mismatch -d "$ROOTDIR" -i "$1" >/dev/null 2>&1; }

# --- platform-tools revision ---------------------------------------------------
# plat_tools_source.prop_template is what adb/fastboot --version, the builder's
# release checks, the official package make-sdk.sh fetches and the release name
# all read. A few tags never bumped it; set the revision they actually are.
case "$TAG" in
  platform-tools-34.0.0) pt_rev=34.0.0 ;;  # says 33.0.4
  platform-tools-34.0.3) pt_rev=34.0.3 ;;  # says 34.0.1
  *) pt_rev= ;;
esac
if [ -n "$pt_rev" ]; then
  sed -i "s/^Pkg\.Revision=.*/Pkg.Revision=$pt_rev/" src/development/sdk/plat_tools_source.prop_template
fi

# --- patches -------------------------------------------------------------------
log "Applying patches"
# adb mDNS: make the Rust adbmdns bridge optional (ADB_NO_RUST_MDNS) so targets
# without a Rust std fall back to openscreen.
apply patches/misc/adb-mdns-openscreen-fallback.patch

# adb mDNS: route target_os=android to the linux netwatch backend so bionic compiles.
apply patches/misc/adbmdns-netwatch-android.patch

# protobuf/upb: disable the aarch64 inline-asm varint path on windows (LLVM can't
# emit SEH unwind info for it); falls back to portable C.
apply patches/misc/upb-aarch64-windows-no-asm.patch

# BoringSSL: CPU detection for every target CPU, and getrandom's syscall number
# from <sys/syscall.h> (x32 trips upstream's expected-number table).
apply patches/misc/boringssl-target-cpus.patch
# Older releases keep that CPU list in base.h; make the same changes there.
if [ ! -f src/boringssl/src/include/openssl/target.h ]; then
  sed -i -E \
    -e 's/^#if defined\(__x86_64\) \|\| defined\(_M_AMD64\) \|\| defined\(_M_X64\)$/#if defined(__arm64ec__) || defined(_M_ARM64EC)\n#define OPENSSL_64_BIT\n#define OPENSSL_AARCH64\n#elif defined(__x86_64) || defined(_M_AMD64) || defined(_M_X64)/' \
    -e 's/^#elif defined\(__AARCH64EL__\) \|\| defined\(_M_ARM64\)$/#elif defined(__AARCH64EL__) || defined(__AARCH64EB__) || defined(_M_ARM64)/' \
    -e 's/^#elif defined\(__ARMEL__\) \|\| defined\(_M_ARM\)$/#elif defined(__ARMEL__) || defined(__ARMEB__) || defined(_M_ARM)/' \
    -e 's/^#elif defined\(__MIPSEL__\) && (!?)defined\(__LP64__\)$/#elif (defined(__MIPSEL__) || defined(__MIPSEB__)) \&\& \1defined(__LP64__)/' \
    -e 's/^#error "Unknown target CPU"$/#if defined(__loongarch64) || defined(__s390x__) || defined(__powerpc64__) || (defined(__riscv) \&\& __riscv_xlen == 64)\n#define OPENSSL_64_BIT\n#elif defined(__powerpc__) || defined(__hexagon__) || (defined(__riscv) \&\& __riscv_xlen == 32)\n#define OPENSSL_32_BIT\n#else\n#error "Unknown target CPU"\n#endif/' \
    src/boringssl/src/include/openssl/base.h
  # Some also have a ppc64le branch keyed on _LITTLE_ENDIAN, which FreeBSD
  # defines on big-endian too, and whose CPU detection calls Linux's
  # getauxval(). No Android.bp builds its assembly; let ppc64 fall through to
  # the plain 64-bit entry above.
  sed -i '/^#elif (defined(__PPC64__) || defined(__powerpc64__)) && defined(_LITTLE_ENDIAN)$/,/^#define OPENSSL_PPC64LE$/d' \
    src/boringssl/src/include/openssl/base.h
  # arm_arch.h (ARMV7_NEON and friends, which the C CPU detection uses) is
  # guarded on the little-endian macros there too.
  sed -i 's/^#if defined(__ARMEL__) || defined(_M_ARM) || defined(__AARCH64EL__) ||/#if defined(__ARMEL__) || defined(__ARMEB__) || defined(_M_ARM) || defined(__AARCH64EL__) || defined(__AARCH64EB__) ||/' \
    src/boringssl/src/include/openssl/arm_arch.h
fi
# The header has moved: crypto/rand (newest), crypto/rand_extra and
# crypto/fipsmodule/rand (older); patch it wherever this release has it.
fillin="$(cd src/boringssl/src && ls crypto/rand/getrandom_fillin.h crypto/rand_extra/getrandom_fillin.h crypto/fipsmodule/rand/getrandom_fillin.h 2>/dev/null | head -n1)"
sed "s#/crypto/rand/getrandom_fillin.h#/${fillin}#" patches/misc/boringssl-getrandom-syscall.patch > "$ROOTDIR/.getrandom.patch"
apply "$ROOTDIR/.getrandom.patch"
rm -f "$ROOTDIR/.getrandom.patch"

# BoringSSL HRSS (hrss.c, hrss.cc from 16) and protobuf's utf8_range: their
# NEON paths mix GNU vector syntax with NEON intrinsics, whose lane order
# disagrees on big-endian ARM; take the portable C paths there. (Older HRSS
# splits its condition over two lines.)
for f in src/boringssl/src/crypto/hrss/hrss.c src/boringssl/src/crypto/hrss/hrss.cc; do
  [ -f "$f" ] || continue
  sed -i -e 's/^\(#\(el\)\?if (defined(OPENSSL_ARM) || defined(OPENSSL_AARCH64)) && defined(__ARM_NEON)\)$/\1 \&\& !defined(__ARM_BIG_ENDIAN)/' \
         -e 's/^\(    (defined(__ARM_NEON__) || defined(__ARM_NEON))\)$/\1 \&\& !defined(__ARM_BIG_ENDIAN)/' "$f"
done
sed -i 's/defined(__ARM_NEON) && defined(__ARM_64BIT_STATE)/& \&\& !defined(__ARM_BIG_ENDIAN)/g' \
  src/protobuf/third_party/utf8_range/utf8_range.c 2>/dev/null || true

# aidl permission/lexer.ll (platform-tools 32.0.0 and earlier): names the
# value type PERMSTYPE, which only older bison's glr.cc defined. It is
# perm::parser::semantic_type, as the grammar's own permlex() declaration says.
sed -i 's/^#define YYSTYPE PERMSTYPE$/#define YYSTYPE perm::parser::semantic_type/' \
  src/aidl/permission/lexer.ll

# diagnose_usb.cpp (platform-tools 32.0.0 and earlier) calls GNU
# group_member(), which musl lacks; use patches/sources/diagnose_usb_in_group.inc.
f=src/core/diagnose_usb/diagnose_usb.cpp
if grep -q 'group_member(plugdev_group->gr_gid)' "$f" 2>/dev/null; then
  sed -i 's/group_member(plugdev_group->gr_gid)/sdk_in_group(plugdev_group->gr_gid)/' "$f"
  awk -v inc="$ROOTDIR/patches/sources/diagnose_usb_in_group.inc" \
    '/^static const char kPermissionsHelpUrl\[\]/ { while ((getline l < inc) > 0) print l } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
fi

# ART: TwoWordReturn by pointer width, so instruction_set.h compiles on any CPU.
apply patches/misc/art-two-word-return.patch

# androidfw: CombinedIterator's proxy reference for newer libc++'s algorithms.
apply patches/misc/androidfw-combined-iterator-libcxx.patch

# selinux: guard host-inert Linux-isms in libselinux so macOS/mingw compile.
patch -p1 -N -s -r - --no-backup-if-mismatch -d src/selinux -i "$ROOTDIR/patches/selinux/0001-host-portability-guards.patch"

log "Applying source fixups${TARGET:+ for $TARGET}"

# --- toolchain / libc++ -----------------------------------------------------
# fmtlib calls bare malloc()/free(); zig 0.17's libc++ doesn't leak the C names,
# so pull in <stdlib.h>.
sed -i '/#define FMT_FORMAT_H_/a #include <stdlib.h>' src/fmtlib/include/fmt/format.h

# fdevent.h names std::vector and adb_mdns.cpp std::atomic without including
# either. Only llvm-mingw's libc++ declines to drag them in, so spell them out.
sed -i '/^#include <variant>$/a #include <vector>' $ADB/fdevent/fdevent.h
sed -i '/^#include <algorithm>$/i #include <atomic>' $ADB/adb_mdns.cpp

# libbase posix_strerror_r.cpp: drop the file's #undef _GNU_SOURCE so the guard
# below sees the GNU char* strerror_r on glibc/bionic; musl keeps the #else.
sed -i '/\/\* Undefine _GNU_SOURCE/,/#undef _GNU_SOURCE/d' $LIBBASE/posix_strerror_r.cpp
sed -i '/return strerror_r(errnum, buf, buflen);/c\
#if (defined(__GLIBC__) || defined(__BIONIC__)) \&\& defined(_GNU_SOURCE)\
  char* msg = strerror_r(errnum, buf, buflen);\
  if (msg != buf) {\
    strncpy(buf, msg, buflen);\
    if (buflen > 0) buf[buflen - 1] = 0;\
  }\
  return 0;\
#else\
  return strerror_r(errnum, buf, buflen);\
#endif' $LIBBASE/posix_strerror_r.cpp

# libbuildversion: stamp a build number into soong_build_number, as the release
# build does after linking. PLACEHOLDER itself stays, or a device (__ANDROID__)
# build would take the number as unstamped and report the device's instead.
sed -i "s/^\( *char soong_build_number\[128\] = \)PLACEHOLDER;/\1\"$(date -u +%y%m%d%H%M%S)\";/" \
  src/soong/cc/libbuildversion/libbuildversion.cpp

# --- Windows (llvm-mingw) -----------------------------------------------------
# Windows <rpc.h> `#define interface struct` clobbers usb_ifc_info's field; #undef it.
sed -i '/^struct usb_ifc_info {/i\
#undef interface  /* Windows <rpc.h> defines this as `struct` */' src/core/fastboot/usb.h

# selinux selinux_internal.h: the integer-pthread_once_t fallback fails on
# macOS/mingw (struct there); call pthread_once directly.
sed -i '/#define __selinux_once(ONCE_CONTROL, INIT_FUNCTION)/i\
#if defined(__APPLE__) || defined(_WIN32)\
#define __selinux_once(ONCE_CONTROL, INIT_FUNCTION) \\\
	pthread_once(\&(ONCE_CONTROL), (INIT_FUNCTION))\
#else' src/selinux/libselinux/src/selinux_internal.h
sed -i '0,/} while (0)/s/} while (0)/} while (0)\
#endif/' src/selinux/libselinux/src/selinux_internal.h

# setrans_client.c: guard out the socket includes (dead code under DISABLE_SETRANS,
# absent on MinGW).
sed -i '/^#include <netdb.h>/i #ifndef _WIN32' src/selinux/libselinux/src/setrans_client.c
sed -i '/^#include <sys\/uio.h>/a #endif' src/selinux/libselinux/src/setrans_client.c

# selinux label_file.h (platform-tools 33.0.3 and older ship e2fsdroid and
# sload_f2fs, which link it): FreeBSD and OpenBSD have no <sys/xattr.h>. Its
# one getxattr() reads restorecon's cached digest; report none stored.
sed -i 's|^#include <sys/xattr.h>$|#if defined(__FreeBSD__) \|\| defined(__OpenBSD__)\n#include <sys/types.h>\n#define getxattr(path, name, value, size) (errno = ENOTSUP, (ssize_t)-1)\n#else\n#include <sys/xattr.h>\n#endif|' src/selinux/libselinux/src/label_file.h

# e2fsprogs ext2fs.h (older releases) includes <sys/types.h> only under
# HAVE_SYS_TYPES_H, which e2fsdroid is built without; musl then lacks dev_t
# and mode_t. Every platform has the header.
sed -i '/^#ifdef HAVE_SYS_TYPES_H$/{N;N;s/^#ifdef HAVE_SYS_TYPES_H\n\(#include <sys\/types.h>\)\n#endif$/\1/}' \
  src/e2fsprogs/lib/ext2fs/ext2fs.h

# e2fsprogs config.h: exclude _WIN32/BSD from HAVE_SYS_SYSMACROS_H (no such header).
sed -i 's/^#if !defined(__APPLE__)$/#if !defined(__APPLE__) \&\& !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  src/e2fsprogs/lib/config.h

# ADB BSD: default is_libusb_enabled() (should_use_libusb() in older adb) to
# the libusb backend, the only one the BSDs have. Windows keeps upstream's
# AdbWinApi default (built from source, see builder/overlay/adbwinapi.bp).
sed -i '/^bool \(is_libusb_enabled\|should_use_libusb\)() {/,/^}/ s/#if defined(__APPLE__)/#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)/' \
  $ADB/client/transport_usb.cpp
# Older still: no platform default at all, only ADB_LIBUSB=1.
sed -i '/^bool should_use_libusb() {/,/^}/ s/^    static bool enable = getenv("ADB_LIBUSB") && strcmp(getenv("ADB_LIBUSB"), "1") == 0;$/#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n    static bool enable = true;\n#else\n&\n#endif/' \
  $ADB/client/transport_usb.cpp

# ADB BSD, platform-tools 31.0.2 and earlier: libusb devices go through the
# shared usb_handle transport (UsbConnection, register_usb_transport) and
# client/usb_dispatch.cpp, which picks libusb:: or native:: per call. There is
# no native backend on the BSDs: send its calls to libusb too, and keep the
# shared transport (patches/sources/adb_usb_bsd.cpp then defines nothing).
if [ -f $ADB/client/usb_dispatch.cpp ]; then
  sed -i '0,/^#include "\(client\/\)\?usb.h"$/s//&\n\n#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n\/\/ No native USB backend on the BSDs: every call goes to libusb.\n#define native libusb\n#endif/' \
    $ADB/client/usb_dispatch.cpp
else
  # ADB BSD: exclude the native BlockingConnection USB path (no native backend,
  # won't link), keeping is_adb_interface()/is_libusb_enabled().
  native_if='#if !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)  // legacy native BlockingConnection USB path'
  if grep -q '^#if ADB_HOST$' $ADB/client/transport_usb.cpp; then
    # platform-tools-34 and earlier: the read helpers sit in #if ADB_HOST/#else/
    # #endif and UsbConnection follows unguarded; some releases then open an
    # #ifdef ADB_HOST block at init_usb_transport() that also holds
    # is_adb_interface(). Guard the pieces without crossing either conditional.
    sed -i "0,/^#if ADB_HOST$/{/^#if ADB_HOST$/i ${native_if}
  }" $ADB/client/transport_usb.cpp
    grep -q '^#ifdef ADB_HOST$' $ADB/client/transport_usb.cpp && sed -i '0,/^#ifdef ADB_HOST$/{/^#ifdef ADB_HOST$/{i #endif  // native USB path
  a '"${native_if}"'
  }}' $ADB/client/transport_usb.cpp
  else
    sed -i "0,/^static int UsbReadMessage(usb_handle\* h, amessage\* msg) {/{/^static int UsbReadMessage(usb_handle\* h, amessage\* msg) {/i ${native_if}
  }" $ADB/client/transport_usb.cpp
  fi
  sed -i '/^\(bool\|int\) is_adb_interface(int usb_class/i #endif  // native USB path\n' \
    $ADB/client/transport_usb.cpp
  # ...and the matching native-transport registration helpers in transport.cpp.
  sed -i '/^void register_usb_transport(usb_handle\* usb,/i #if !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)  // native usb_handle transport registration' \
    $ADB/transport.cpp
  # Close it right after unregister_usb_transport(): older adb keeps more host
  # code (atransport's reverse config) before the enclosing #endif.
  sed -i '/^void unregister_usb_transport(usb_handle\* usb) {/,/^}/ { /^}/a #endif  // native USB path
  }' $ADB/transport.cpp
fi

# ADB Windows: make usb_libusb_hotplug.cpp's timeval time_t->long cast explicit.
sed -i 's/struct timeval timeout{(time_t)libusb_inhouse_hotplug::kScan_rate_s.count(), 0};/struct timeval timeout{static_cast<long>(libusb_inhouse_hotplug::kScan_rate_s.count()), 0};/' \
  $ADB/client/usb_libusb_hotplug.cpp

# ADB older releases (platform-tools 35.0.2 and earlier): usb_init() aborts
# when libusb has no hotplug, which no BSD backend has. Scan for devices instead
# (patches/sources/adb_libusb_scan.inc), as newer adb's in-house hotplug does.
f=$ADB/client/usb_libusb.cpp
if grep -q 'LOG(FATAL) << "failed to register libusb hotplug callback";' "$f" 2>/dev/null; then
  sed -i 's/^#include <atomic>$/#include <algorithm>\n&\n#include <vector>/' "$f"
  awk -v inc="$ROOTDIR/patches/sources/adb_libusb_scan.inc" \
    '/^void usb_init\(\) \{$/ { while ((getline l < inc) > 0) print l } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i 's/^        LOG(FATAL) << "failed to register libusb hotplug callback";$/        sdk_scan_usb_devices();/' "$f"
fi

# adb client/auth.cpp: adb_auth_sign() returns nullptr as a std::string for a
# token of the wrong size, which a device controls; return an empty one.
sed -i '/^static std::string adb_auth_sign(/,/^}/ s/^        return nullptr;$/        return {};/' \
  $ADB/client/auth.cpp

# ADB Windows: reinterpret_cast OSVERSIONINFO* to PRTL_OSVERSIONINFOW in sysdeps_win32.cpp.
sed -i 's/static_cast<PRTL_OSVERSIONINFOW>(&version)/reinterpret_cast<PRTL_OSVERSIONINFOW>(\&version)/' \
  $ADB/sysdeps_win32.cpp

# ADB Windows: reinterpret_cast adb_stat* to _stat64* for wstat() in stat.cpp.
sed -i 's/wstat(path_wide\.c_str(), &st)/wstat(path_wide.c_str(), reinterpret_cast<struct _stat64*>(\&st))/' \
  $ADB/sysdeps/win32/stat.cpp

# --- AdbWinApi (Windows) ----------------------------------------------------
# builder/overlay/adbwinapi.bp links AdbWinApi and AdbWinUsbApi into adb and
# fastboot instead of shipping Google's prebuilt DLLs. Their API is then
# neither exported nor imported...
awa=src/development/host/windows/usb
# AOSP ships these with CRLF line endings, which the $-anchored edits below
# would never match.
sed -i 's/\r$//' "$awa"/api/* "$awa"/winusb/*
sed -i 's/^#ifdef ADBWIN_EXPORTS$/#if defined(ADBWIN_STATIC)\n#define ADBWIN_API EXTERN_C\n#define ADBWIN_API_CLASS\n#elif defined(ADBWIN_EXPORTS)/' \
  "$awa/api/adb_api.h"
# ...the routine AdbWinApi.dll would fetch from AdbWinUsbApi.dll at load time is
# a direct reference (patches/sources/adbwinapi_static.cpp)...
sed -i 's/^PFN_INSTWINUSBINTERFACE InstantiateWinUsbInterface = NULL;$/#if defined(ADBWIN_STATIC)\nextern "C" AdbInterfaceObject* __cdecl AdbWinUsbApiInstantiateWinUsbInterface(const wchar_t*);\nPFN_INSTWINUSBINTERFACE InstantiateWinUsbInterface = AdbWinUsbApiInstantiateWinUsbInterface;\n#else\n&\n#endif/' \
  "$awa/api/adb_api.cpp"
# ...the WinUSB half's includes of the API half use Windows separators...
sed -i 's|^#include "\.\.\\api\\\(.*\)"$|#include "../api/\1"|' "$awa"/winusb/*.h
# ...and handle-returning functions return false for NULL, which stopped being
# a null pointer constant in C++11.
sed -i '/^ADBAPIHANDLE /,/^}/ s/\breturn false;/return NULL;/' "$awa"/api/*.cpp "$awa"/winusb/*.cpp

# --- arm64ec (Windows) ------------------------------------------------------
# protobuf guards its x86 asm on __x86_64__ in several spellings; arm64ec
# defines it but assembles none of it, and every site has a portable #else.
# So require a non-EC target at every __x86_64__ test.
grep -rl 'defined(__x86_64__)' src/protobuf/src 2>/dev/null | while read -r _f; do
  sed -i 's@defined(__x86_64__)@(defined(__x86_64__) \&\& !defined(__arm64ec__))@g' "$_f"
done

# abseil's prefetch.h emits x86 prefetchw for __x86_64__; arm64ec has no such
# mnemonic. Exclude EC and it falls to the portable __builtin_prefetch #else.
sed -i 's@^#if defined(__x86_64__) \&\& !defined(__PRFCHW__)$@#if defined(__x86_64__) \&\& !defined(__PRFCHW__) \&\& !defined(__arm64ec__)@' src/abseil-cpp/absl/base/prefetch.h

# abseil's unscaledcycleclock picks Now()/Frequency() by arch: arm64ec defines
# __x86_64__ but not __aarch64__, so it took the rdtsc branch. Send it to the ARM
# one, which aarch64-w64-mingw32 already uses.
sed -i -e 's@^#if defined(__x86_64__)$@#if defined(__x86_64__) \&\& !defined(__arm64ec__)@' \
       -e 's@^#elif defined(__x86_64__)$@#elif defined(__x86_64__) \&\& !defined(__arm64ec__)@' \
       -e 's@^#elif defined(__aarch64__)$@#elif defined(__aarch64__) || defined(__arm64ec__)@' \
    src/abseil-cpp/absl/base/internal/unscaledcycleclock.h \
    src/abseil-cpp/absl/base/internal/unscaledcycleclock.cc

# abseil's random platform.h picks ABSL_ARCH_* by macro, so arm64ec lands on
# X86_64 and randen_detect.cc reaches for __cpuid that mingw's <intrin.h> has no
# ARM declaration for. Leave the arch undefined instead: the #else is empty, so
# AES acceleration and dispatch stay off and randen takes its portable path.
sed -i 's@^#define ABSL_ARCH_X86_64$@#if !defined(__arm64ec__)\n#define ABSL_ARCH_X86_64\n#endif@' src/abseil-cpp/absl/random/internal/platform.h

# abseil's crc cpu_detect.cc gates __cpuid on __x86_64__, but on arm64ec clang has
# no x86 builtin and the asm fallback is !_WIN32, so nothing declares it. Exclude EC
# and GetCpuType() returns its kUnknown fallback.
sed -i 's@defined(__x86_64__) || defined(_M_X64)@(defined(__x86_64__) || defined(_M_X64)) \&\& !defined(__arm64ec__)@g' src/abseil-cpp/absl/crc/internal/cpu_detect.cc

# arm64ec defines __x86_64__/_M_X64 so datatype layouts match x64, but every use of
# them in zstd is instruction-level -- cpuid asm, cmova in ZSTD_selectAddr, .p2align
# hints (which also break SEH unwind info), BMI2 -- so require a non-EC target for
# all of them. Each site has a portable #else.
grep -rl 'defined(__x86_64__)\|defined(_M_X64)' src/zstd/lib 2>/dev/null | while read -r _f; do
  sed -i -e 's@defined(__x86_64__)@(defined(__x86_64__) \&\& !defined(__arm64ec__))@g' \
         -e 's@defined(_M_X64)@(defined(_M_X64) \&\& !defined(_M_ARM64EC))@g' "$_f"
done

# --- CPUs AOSP never builds for (hexagon, mips, ppc, riscv32, s390x, ...) -----
# riscv32/powerpc/mips: drop the std::atomic is_always_lock_free static_assert.
case "$TARGET" in
  riscv32-*|powerpc-*|mips-*|mipsel-*)
    sed -i 's/^\([[:space:]]*\)static_assert(std::atomic<.*>::is_always_lock_free);/\1\/\/ &/' src/art/libartbase/base/metrics/metrics.h
    ;;
esac

# cacheflush(): ART's 32-bit ARM path calls it, but only bionic has it. Elsewhere
# it becomes the compiler runtime's __clear_cache, or on mingw Win32's
# FlushInstructionCache (declared by hand: <windows.h> must stay behind
# utils.cc's own ERROR-macro handling).
sed -i '/#include "os.h"/a\
#if defined(__arm__)\
#if defined(_WIN32)\
extern "C" __declspec(dllimport) void* __stdcall GetCurrentProcess(void);\
extern "C" __declspec(dllimport) int __stdcall FlushInstructionCache(void*, const void*, unsigned long);\
static inline int cacheflush(void* addr, int size, int) {\
  return FlushInstructionCache(GetCurrentProcess(), addr, (unsigned long)size) ? 0 : -1;\
}\
#elif !defined(__BIONIC__)\
static inline int cacheflush(void* addr, int size, int) {\
  __builtin___clear_cache(static_cast<char*>(addr), static_cast<char*>(addr) + size);\
  return 0;\
}\
#else\
#include <sys/cachectl.h>\
#endif\
#endif' src/art/libartbase/base/utils.cc
sed -i '/int r = cacheflush(start, limit, kCacheFlushFlags);/{
s/.*/#if defined(__arm__) \&\& !defined(__aarch64__)\
\
  void* addr = reinterpret_cast<void*>(start);\
  int size = static_cast<int>(limit - start);\
#if defined(__BIONIC__)\
  int r = cacheflush(reinterpret_cast<long>(addr), static_cast<long>(size), static_cast<long>(kCacheFlushFlags));\
#else\
  int r = cacheflush(addr, size, kCacheFlushFlags);\
#endif\
#else\
  int r = cacheflush(start, limit, kCacheFlushFlags);\
#endif/
}' src/art/libartbase/base/utils.cc
sed -i '/FlushCpuCaches/,/}/ {
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/i #if !defined(__s390x__) && !defined(__ppc__) && !defined(__hexagon__) && !defined(__riscv)
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/a #endif
}' src/art/libartbase/base/utils.cc

# abseil ppc32 stacktrace: musl exposes regs as uc_mcontext.gregs[] (glibc uses
# uc_mcontext.uc_regs->gregs[]). Rewrite for musl ppc32 only.
case "$TARGET" in
  powerpc-*musl*)
    for f in src/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc \
             src/abseil-cpp/absl/debugging/internal/examine_stack.cc; do
      [ -f "$f" ] && sed -i 's/uc_mcontext\.uc_regs->gregs/uc_mcontext.gregs/g' "$f"
    done
    ;;
esac

# abseil direct_mmap.h asserts "no __NR_mmap2 => 64-bit", wrong for 32-bit
# generic-syscall arches (riscv32, hexagon); use a libc mmap() fallback on non-LP64.
sed -i 's@^\([[:space:]]*\)static_assert(sizeof(unsigned long) == 8, "Platform is not 64-bit");@#if !defined(__LP64__)\n\1return mmap(start, length, prot, flags, fd, offset);\n#endif@' \
  "src/abseil-cpp/absl/base/internal/direct_mmap.h"

# abseil examine_stack.cc: add hexagon to GetProgramCounter() (musl mcontext_t is
# struct sigcontext with .pc).
sed -i '/^#else$/{N;s/^#else\n#error "Undefined Architecture."/#elif defined(__hexagon__)\n    return reinterpret_cast<void*>(context->uc_mcontext.pc);\n#else\n#error "Undefined Architecture."/;}' \
  "src/abseil-cpp/absl/debugging/internal/examine_stack.cc"

# abseil conditions.h: drop hexagon from the Win32 guard so <unistd.h> declares _exit.
sed -i 's/^#if defined(_WIN32) || defined(__hexagon__)$/#if defined(_WIN32)/' \
  "src/abseil-cpp/absl/log/internal/conditions.h"

# liblog logger_name.cpp: hexagon Clang makes android_LogPriority unsigned char,
# tripping the uint32_t static_asserts; guard them under !__hexagon__.
sed -i '/^static_assert(std::is_same<std::underlying_type<log_id_t>::type, uint32_t>::value,$/i #ifndef __hexagon__' $LIBLOG/logger_name.cpp
sed -i '/^static_assert(std::is_same<std::underlying_type<android_LogPriority>::type, uint32_t>::value,$/i #ifndef __hexagon__' $LIBLOG/logger_name.cpp
sed -i '/^              "log_id_t must be an uint32_t");$/a #endif' $LIBLOG/logger_name.cpp

# adb sysdeps/errno.cpp: guard out the ERRNO_VALUE static_asserts on MIPS (its
# errno numbers differ from the ADB wire values); the runtime switch still works.
sed -i 's@#define ERRNO_VALUE(error_name, wire_value) static_assert((error_name) == (wire_value), "")@#if !defined(__mips__)\n#define ERRNO_VALUE(error_name, wire_value) static_assert((error_name) == (wire_value), "")\n#else\n#define ERRNO_VALUE(error_name, wire_value) /* mips errno numbers differ from ADB wire values */\n#endif@' \
    $ADB/sysdeps/errno.cpp

# --- bionic below API 29 ------------------------------------------------------
# The bionic tools target API 24; these guard uses of API 29+ symbols.
sed -i 's/#if defined(__BIONIC__)/#if defined(__BIONIC__) \&\& __ANDROID_API__ >= 29/g' $LIBBASE/include/android-base/unique_fd.h $ZIPARCHIVE/zip_archive.cc src/art/libartbase/base/unix_file/fd_file.cc
sed -i 's/__INTRODUCED_IN([0-9]*)//g' $LIBLOG/include/android/log.h $ADB/pairing_connection/include/adb/pairing/pairing_connection.h $ADB/pairing_auth/include/adb/pairing/pairing_auth.h
sed -i 's/^#if !defined(__BIONIC__)$/#if !defined(__BIONIC__) || __ANDROID_API__ < 29/' src/core/libcutils/native_handle.cpp
sed -i 's/^#ifdef __BIONIC__$/#if defined(__BIONIC__) \&\& __ANDROID_API__ >= 29/' src/core/libcutils/native_handle.cpp

# e2fsprogs ismounted.c: without getmntent/getmntinfo (our BSD, macOS and
# Windows configs) it reports nothing mounted and #warns about it on every
# build. That only matters for live disks, not the images these tools write.
sed -i "s|^ #warning \"Can't use getmntent or getmntinfo to check for mounted filesystems!\"$| /* no getmntent/getmntinfo: nothing is reported as mounted */|" \
  src/e2fsprogs/lib/ext2fs/ismounted.c

# e2fsprogs error-table sources: rename the 'link' var (collides with POSIX
# link() on bionic) to 'et_link'.
for f in lib/support/prof_err.c lib/ext2fs/ext2_err.c; do
  sed -i 's/\blink\b/et_link/g' "src/e2fsprogs/$f"
done

# --- BSD --------------------------------------------------------------------
# Soong has no BSD target: these add BSD branches next to the Linux/macOS ones.
# libbase GetThreadId() has none, so it falls off a non-void function and
# clang's trap crashes adb at startup. Add the BSD calls and headers.
sed -i '/#include <unistd.h>/a\
#if defined(__FreeBSD__)\n#include <pthread_np.h>\n#elif defined(__NetBSD__)\n#include <lwp.h>\n#endif' $LIBBASE/threads.cpp
sed -i '/return syscall(__NR_gettid);/a\
#elif defined(__FreeBSD__)\n  return pthread_getthreadid_np();\n#elif defined(__NetBSD__)\n  return _lwp_self();\n#elif defined(__OpenBSD__)\n  return getthrid();' $LIBBASE/threads.cpp

# libcutils threads.cpp's gettid() fallback and liblog's GetThreadId(), which
# its stderr logger calls for every line, have no BSD branch either and fall
# off the end. Give them the same calls.
bsd_tid_inc='#if defined(__FreeBSD__)\n#include <pthread_np.h>\n#elif defined(__NetBSD__)\n#include <lwp.h>\n#elif defined(__OpenBSD__)\n#include <unistd.h>\n#endif'
bsd_tid_ret='#elif defined(__FreeBSD__)\n  return pthread_getthreadid_np();\n#elif defined(__NetBSD__)\n  return _lwp_self();\n#elif defined(__OpenBSD__)\n  return getthrid();'
for f in src/core/libcutils/threads.cpp:'pid_t gettid() {' $LIBLOG/logger_write.cpp:'static uint64_t GetThreadId() {'; do
  file="${f%%:*}"; fn="${f#*:}"
  [ -f "$file" ] && grep -qxF "$fn" "$file" || continue
  sed -i "/^$fn\$/,/^}/ s/^  return syscall(__NR_gettid);\$/&\n$bsd_tid_ret/" "$file"
  sed -i "0,/^$fn\$/s//$bsd_tid_inc\n\n&/" "$file"
done

# PosixUtils: 'stdout'/'stderr' are macros on the BSDs. Rename the .cpp's pipe
# locals to out_fd/err_fd, and older releases' ProcResult fields (header and
# .cpp) to the stdout_str/stderr_str newer ones use.
case "$TARGET" in
  *-freebsd-*|*-netbsd-*|*-openbsd-*)
    sed -i \
      -e 's/int stdout\[2\]/int out_fd[2]/g' \
      -e 's/int stderr\[2\]/int err_fd[2]/g' \
      -e 's/pipe(stdout)/pipe(out_fd)/g' \
      -e 's/pipe(stderr)/pipe(err_fd)/g' \
      -e 's/stdout\[/out_fd[/g' \
      -e 's/stderr\[/err_fd[/g' \
      -e 's/result->stdout =/result->stdout_str =/' \
      -e 's/result->stderr =/result->stderr_str =/' \
      src/base/libs/androidfw/PosixUtils.cpp
    sed -i -e 's/^  std::string stdout;$/  std::string stdout_str;/' \
           -e 's/^  std::string stderr;$/  std::string stderr_str;/' \
      src/base/libs/androidfw/include/androidfw/PosixUtils.h

    # utils.cc: add BSD branches to GetTid() (pthread_self) and SetThreadName()
    # (FreeBSD 2-arg, NetBSD 3-arg, OpenBSD none).
    python3 << 'PYEOF'
import sys

with open('src/art/libartbase/base/utils.cc', 'r') as f:
    content = f.read()

# GetTid(): add BSD elif before generic #else that uses __NR_gettid
old1 = ('#elif defined(_WIN32)\n'
        '  return static_cast<pid_t>(::GetCurrentThreadId());\n'
        '#else\n'
        '  return syscall(__NR_gettid);')
new1 = ('#elif defined(_WIN32)\n'
        '  return static_cast<pid_t>(::GetCurrentThreadId());\n'
        '#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n'
        '  return static_cast<uint32_t>((uintptr_t)pthread_self());\n'
        '#else\n'
        '  return syscall(__NR_gettid);')
if old1 in content:
    content = content.replace(old1, new1, 1)
    print('GetTid BSD patch applied')
else:
    print('GetTid BSD patch: pattern not found (already applied?)')

# SetThreadName(): extend Linux/Win guard to include FreeBSD (same 2-arg API)
old2 = '#if defined(__linux__) || defined(_WIN32)\n  // pthread_setname_np fails rather than truncating long strings.'
new2 = '#if defined(__linux__) || defined(_WIN32) || defined(__FreeBSD__)\n  // pthread_setname_np fails rather than truncating long strings.'
if old2 in content:
    content = content.replace(old2, new2, 1)
    print('SetThreadName FreeBSD guard patch applied')
else:
    print('SetThreadName FreeBSD guard patch: pattern not found (already applied?)')

# SetThreadName(): insert NetBSD (3-arg) and OpenBSD (no-op) before macOS else
old3 = """#else  // __APPLE__
  if (pthread_equal(thr, pthread_self())) {
    pthread_setname_np(thread_name);
  } else {
    PLOG(WARNING) << "Unable to set the name of another thread to '" << thread_name << "'";
  }
#endif"""
new3 = """#elif defined(__NetBSD__)
  {
    char buf_netbsd[16];
    strncpy(buf_netbsd, s, sizeof(buf_netbsd) - 1);
    buf_netbsd[sizeof(buf_netbsd) - 1] = '\\0';
    pthread_setname_np(thr, "%s", buf_netbsd);
  }
#elif defined(__OpenBSD__)
  (void)thr; (void)s;
#else  // __APPLE__
  if (pthread_equal(thr, pthread_self())) {
    pthread_setname_np(thread_name);
  } else {
    PLOG(WARNING) << "Unable to set the name of another thread to '" << thread_name << "'";
  }
#endif"""
# Older ART (platform-tools-35.0.1 and before) only names the current thread.
old3b = """#else  // __APPLE__
  pthread_setname_np(thread_name);
#endif"""
new3b = """#elif defined(__NetBSD__)
  {
    char buf_netbsd[16];
    strncpy(buf_netbsd, s, sizeof(buf_netbsd) - 1);
    buf_netbsd[sizeof(buf_netbsd) - 1] = '\\0';
    pthread_setname_np(pthread_self(), "%s", buf_netbsd);
  }
#elif defined(__OpenBSD__)
  (void)s;
#else  // __APPLE__
  pthread_setname_np(thread_name);
#endif"""
if old3 in content:
    content = content.replace(old3, new3, 1)
    print('SetThreadName BSD elif patch applied')
elif old3b in content:
    content = content.replace(old3b, new3b, 1)
    print('SetThreadName BSD elif patch applied (older ART)')
else:
    print('SetThreadName BSD elif patch: pattern not found (already applied?)')

with open('src/art/libartbase/base/utils.cc', 'w') as f:
    f.write(content)
PYEOF
    ;;
esac

# gtest-port.cc: on FreeBSD AArch64 <machine/proc.h>'s struct ptrauth_key clashes
# with clang's builtin; guard the include and stub GetThreadCount().
sed -i '/^#include <sys\/user.h>$/i #if !defined(__FreeBSD__) || !defined(__aarch64__)' \
  "src/googletest/googletest/src/gtest-port.cc"
sed -i '/^#include <sys\/user.h>$/a #endif' \
  "src/googletest/googletest/src/gtest-port.cc"
sed -i '/#elif defined(GTEST_OS_DRAGONFLY) || defined(GTEST_OS_FREEBSD) || \\$/{
  N
  s/#elif defined(GTEST_OS_DRAGONFLY) || defined(GTEST_OS_FREEBSD) || \\\n    defined(GTEST_OS_GNU_KFREEBSD) || defined(GTEST_OS_NETBSD)/#elif defined(GTEST_OS_FREEBSD) \&\& defined(__aarch64__)\nsize_t GetThreadCount() { return 0; }\n#elif defined(GTEST_OS_DRAGONFLY) || defined(GTEST_OS_FREEBSD) || \\\n    defined(GTEST_OS_GNU_KFREEBSD) || defined(GTEST_OS_NETBSD)/
}' "src/googletest/googletest/src/gtest-port.cc"

# off64_t.h: BSDs don't have a separate off64_t type (off_t is always 64-bit).
sed -i 's/^#if defined(__APPLE__)$/#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)/' \
  "$LIBBASE/include/android-base/off64_t.h"

# libbase file.cpp: GetExecutablePath() has no BSD branch. adb execs it to
# start the server, so it must be a real path
# (patches/sources/libbase_bsd_exe_path.inc), not getprogname()'s bare name.
# (Older releases have no __EMSCRIPTEN__ branch to put it before; use the
# function's final #else there.)
f=$LIBBASE/file.cpp
if [ -f "$f" ]; then
  awk -v inc="$ROOTDIR/patches/sources/libbase_bsd_exe_path.inc" \
    '/^std::string GetExecutablePath\(\) \{$/ { while ((getline l < inc) > 0) print l } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  if grep -q '^#elif defined(__EMSCRIPTEN__)' "$f"; then
    sed -i 's/#elif defined(__EMSCRIPTEN__)/#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n  return sdk_bsd_executable_path();\n#elif defined(__EMSCRIPTEN__)/' "$f"
  else
    sed -i '/^std::string GetExecutablePath() {/,/^}/ s/^#else$/#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n  return sdk_bsd_executable_path();\n#else/' "$f"
  fi
fi

# adb sysdeps_unix.cpp: network_peek() sizes the next UDP datagram (mDNS) with
# recv(MSG_PEEK | MSG_TRUNC), which only Linux answers with the full length;
# the caller CHECKs recvmsg against it. On the BSDs peek into a buffer as large
# as any datagram instead.
sed -i 's/^    upper_bound_bytes = recv(fd.get(), nullptr, 0, MSG_PEEK | MSG_TRUNC);$/#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n    static thread_local char peek_buf[65536];\n    upper_bound_bytes = recv(fd.get(), peek_buf, sizeof(peek_buf), MSG_PEEK);\n#else\n&\n#endif/' \
  $ADB/sysdeps_unix.cpp 2>/dev/null || true

# adb openscreen udp_socket.cpp: NetBSD's IP_PKTINFO sets a default source
# (struct); the multicast join's "deliver IP_PKTINFO" switch is IP_RECVPKTINFO.
sed -i 's/adb_setsockopt(fd_, IPPROTO_IP, IP_PKTINFO, &enable_pktinfo,/adb_setsockopt(fd_, IPPROTO_IP, SDK_IP_PKTINFO_ON, \&enable_pktinfo,/' \
  $ADB/client/openscreen/platform/udp_socket.cpp 2>/dev/null &&
sed -i '0,/^#include /s//#if defined(__NetBSD__)\n#define SDK_IP_PKTINFO_ON IP_RECVPKTINFO\n#else\n#define SDK_IP_PKTINFO_ON IP_PKTINFO\n#endif\n&/' \
  $ADB/client/openscreen/platform/udp_socket.cpp || true

# libbase logging.cpp: the getprogname() fallback uses glibc-only
# program_invocation_short_name; BSDs have native getprogname().
sed -i 's/^#if !defined(__APPLE__) \&\& !defined(__BIONIC__)$/#if !defined(__APPLE__) \&\& !defined(__BIONIC__) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  "$LIBBASE/logging.cpp"

# libbase cmsg.cpp: <sys/user.h> is unused here and does not exist on NetBSD.
sed -i 's|#include <sys/user.h>|#if !defined(__NetBSD__)\n#include <sys/user.h>\n#endif|' \
  "$LIBBASE/cmsg.cpp"

# googletest gtest-port.cc (older releases): FreeBSD aarch64's <sys/user.h>
# clashes with clang's ptrauth_key. Skip it there and report no thread count,
# as later googletest does.
sed -i -e 's/^#  include <sys\/user.h>$/#  if !defined(__FreeBSD__) || !defined(__aarch64__)\n#   include <sys\/user.h>\n#  endif/' \
  -e 's/^#elif GTEST_OS_DRAGONFLY || GTEST_OS_FREEBSD || GTEST_OS_GNU_KFREEBSD || \\$/#elif GTEST_OS_FREEBSD \&\& defined(__aarch64__)\nsize_t GetThreadCount() { return 0; }\n&/' \
  src/googletest/googletest/src/gtest-port.cc

# liblog logger_write.cpp: same getprogname() fallback issue.
sed -i 's/^#if !defined(__APPLE__) \&\& !defined(__BIONIC__)$/#if !defined(__APPLE__) \&\& !defined(__BIONIC__) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  "$LIBLOG/logger_write.cpp"

# protobuf port_def.inc: older releases enable [[clang::musttail]] on every CPU
# but a denylist, and LLVM's backend can't honour it on mips64 and others
# ("failed to perform tail call elimination"). Newer ones allow only aarch64
# and x86_64; take that list wherever the old one is still there.
python3 << 'PYEOF'
import re

path = 'src/protobuf/src/google/protobuf/port_def.inc'
with open(path) as f:
    content = f.read()
old = re.compile(r'#if (ABSL_HAVE_CPP_ATTRIBUTE|__has_cpp_attribute)\(clang::musttail\) && !defined\(__arm__\)(?:[^\n]*\\\n)*[^\n]*\n')
m = old.search(content)
if m:
    content = (content[:m.start()] + '#if %s(clang::musttail) && (defined(__aarch64__) || \\\n'
               '    (defined(__x86_64__) && !defined(__arm64ec__)) || defined(_M_X64))\n' % m.group(1)
               + content[m.end():])
    with open(path, 'w') as f:
        f.write(content)
    print('protobuf musttail: limited to aarch64/x86_64')
PYEOF

# fastboot_driver_interface.h: older releases use std::vector without <vector>,
# which only llvm-mingw's libc++ doesn't pull in some other way. Upstream added
# the include later.
grep -q '^#include <vector>' src/core/fastboot/fastboot_driver_interface.h ||
  sed -i 's/^#include <string>$/#include <string>\n#include <vector>/' src/core/fastboot/fastboot_driver_interface.h

# abseil stacktrace.cc (older releases): without <alloca.h> it declares its own
# static alloca(), which the BSDs' <stdlib.h> already declares (NetBSD fails).
# Take theirs; a no-op where the fallback is gone.
sed -i 's/^#elif !defined(alloca)$/#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n#include <stdlib.h>\n#define ABSL_INTERNAL_HAVE_ALLOCA 1\n#elif !defined(alloca)/' \
  src/abseil-cpp/absl/debugging/stacktrace.cc

# libbase properties.cpp (older releases): prop_info_cmp's operator()s are not
# const, and newer libc++ (zig's) calls the comparator through a const object.
# Upstream made them const later.
sed -i -E 's/^(  bool operator\(\)\((const prop_info& lhs|std::string_view lhs), [^)]*\)) \{/\1 const {/' \
  $LIBBASE/properties.cpp

# e2fsprogs quotaio.h (older releases): quota_write_inode() is declared with an
# enum quota_type but defined with unsigned int qtype_bits; hexagon's enums are
# not unsigned int, so the two conflict. Declare it as upstream later did.
sed -i 's/^errcode_t quota_write_inode(quota_ctx_t qctx, enum quota_type qtype);$/errcode_t quota_write_inode(quota_ctx_t qctx, unsigned int qtype_bits);/' \
  src/e2fsprogs/lib/support/quotaio.h

# fmt 10 (older releases): newer clang rejects its consteval format-string
# check ("not valid in a constant expression" in format-inl.h). Turn the
# compile-time check off; formatting itself is unchanged.
if grep -q '^#define FMT_VERSION 10' src/fmtlib/include/fmt/core.h 2>/dev/null; then
  grep -q '^#define FMT_CONSTEVAL$' src/fmtlib/include/fmt/core.h ||
    sed -i 's/^#ifndef FMT_CONSTEVAL$/#define FMT_CONSTEVAL\n#ifndef FMT_CONSTEVAL/' src/fmtlib/include/fmt/core.h
fi

# f2fs-tools fsck/main.c (platform-tools 30.0.0 to 33.0.2): times the run
# with CLOCK_BOOTTIME unguarded, which NetBSD lacks. Later releases check
# HAVE_CLOCK_BOOTTIME; fall back to CLOCK_MONOTONIC where it is missing.
sed -i 's/^\tclock_gettime(CLOCK_BOOTTIME, &t);$/#ifdef CLOCK_BOOTTIME\n\tclock_gettime(CLOCK_BOOTTIME, \&t);\n#else\n\tclock_gettime(CLOCK_MONOTONIC, \&t);\n#endif/' src/f2fs-tools/fsck/main.c

# f2fs-tools f2fs_fs.h (older releases): typedefs bool, a keyword in the C23
# we build C as. Keep it for older C only; upstream dropped it later.
sed -i 's/^#ifndef bool$/#if !defined(bool) \&\& (!defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L) \&\& !defined(__cplusplus)/' \
  src/f2fs-tools/include/f2fs_fs.h

# f2fs-tools on the BSDs: android_config.h has Linux/macOS/Windows blocks only,
# so give them one (lseek64 comes from host_compat.h). The device size ioctls
# are FreeBSD's/NetBSD's byte counts; OpenBSD has none, so only files size there.
grep -q '__NetBSD__' src/f2fs-tools/include/android_config.h ||
  sed -i '/^#if defined(_WIN32)$/i \
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\
#define HAVE_FCNTL_H 1\
#define HAVE_STDLIB_H 1\
#define HAVE_STRING_H 1\
#define HAVE_SYS_IOCTL_H 1\
#define HAVE_SYS_MOUNT_H 1\
#define HAVE_SYS_UTSNAME_H 1\
#define HAVE_UNISTD_H 1\
#define HAVE_CLOCK_GETTIME 1\
#define HAVE_FSTAT 1\
#define HAVE_FSYNC 1\
#define HAVE_LSEEK64 1\
#define HAVE_MEMSET 1\
#define HAVE_PREAD 1\
#define HAVE_PWRITE 1\
#define HAVE_SPARSE_SPARSE_H 1\
#define HAVE_LIBLZ4 1\
#ifdef WITH_SLOAD\
#define HAVE_LIBSELINUX 1\
#endif\
#endif\
' src/f2fs-tools/include/android_config.h
grep -q 'DIOCGMEDIASIZE' src/f2fs-tools/lib/libf2fs.c ||
  sed -i '/^#endif \/\* APPLE_DARWIN \*\/$/a \
\
#if defined(__FreeBSD__)\
#include <sys/disk.h>\
#elif defined(__NetBSD__)\
#include <sys/dkio.h>\
#endif\
#if defined(__FreeBSD__) || defined(__NetBSD__)\
#define BLKGETSIZE64	DIOCGMEDIASIZE\
#define BLKSSZGET	DIOCGSECTORSIZE\
#elif defined(__OpenBSD__)\
#define BLKGETSIZE64	0\
#endif' src/f2fs-tools/lib/libf2fs.c

# ICU's double-conversion #errors on CPUs outside its list of those with exact
# IEEE doubles. Hexagon's (hardware or soft-float) are, as are LoongArch's and
# RISC-V's, which older releases' copies do not list yet.
dc=src/icu/icu4c/source/i18n/double-conversion-utils.h
grep -q '__hexagon__' "$dc" || {
  sed -i 's/^#if defined(_M_X64) || defined(__x86_64__) || \\$/#if defined(_M_X64) || defined(__x86_64__) || defined(__hexagon__) || defined(__loongarch__) || defined(__riscv) || \\/' "$dc"
  grep -q '__hexagon__' "$dc"
}

# ART mem_map.h (older releases): only aarch64/riscv/Apple get the low-4G
# allocator, other 64-bit CPUs #error (loongarch64, mips64, ppc64, s390x).
# Newer ART uses it on every 64-bit host; do so for all but x86_64, which
# keeps its MAP_32BIT path.
sed -i -e 's/(defined(__aarch64__) || defined(__riscv) || defined(__APPLE__))$/(!defined(__x86_64__) || defined(__APPLE__))/' \
  -e 's/(defined(__aarch64__) || defined(__APPLE__))$/(!defined(__x86_64__) || defined(__APPLE__))/' \
  src/art/libartbase/base/mem_map.h

# adb sysdeps/env.cpp (platform-tools-35.0.1 and earlier): calls getenv()
# without <stdlib.h>, which musl's headers do not pull in. Upstream added it.
if [ -f $ADB/sysdeps/env.cpp ] && ! grep -q '^#include <stdlib.h>' $ADB/sysdeps/env.cpp; then
  sed -i '0,/^#include "sysdeps\/env.h"$/s//#include <stdlib.h>\n\n#include "sysdeps\/env.h"/' $ADB/sysdeps/env.cpp
fi

# aapt2 util/Files (platform-tools-35.0.1 and earlier): BuildPath() takes a
# std::vector of const StringPiece, which newer libc++ rejects (no allocator
# for const types). Upstream later changed the signature; drop the const.
sed -i 's/std::vector<const android::StringPiece>&& args/std::vector<android::StringPiece>\&\& args/; s/std::vector<const StringPiece>&& args/std::vector<StringPiece>\&\& args/' \
  src/base/tools/aapt2/util/Files.h src/base/tools/aapt2/util/Files.cpp

# libpng pngpriv.h (older releases): takes classic Mac OS's <fp.h> whenever
# TARGET_OS_MAC is defined, which modern macOS SDKs define without shipping
# <fp.h>. Newer libpng dropped the branch; stop macOS from taking it.
sed -i 's/    defined(THINK_C) || defined(__SC__) || defined(TARGET_OS_MAC)$/    defined(THINK_C) || defined(__SC__)/' src/libpng/pngpriv.h

# zlib zutil.h (platform-tools 34.0.5 and older): the same classic Mac OS
# check, which #defines fdopen() to NULL and breaks the SDK's stdio.h
# declaration of it. zlib dropped TARGET_OS_MAC there in 35.0.1.
sed -i 's/^#if defined(MACOS) || defined(TARGET_OS_MAC)$/#if defined(MACOS)/' src/zlib/zutil.h

# ART globals.h (platform-tools-35.0.1): GetPageSizeSlow() calls sysconf()
# unconditionally, which Windows lacks. Later releases fall back to 4096.
f=src/art/libartbase/base/globals.h
if [ -f "$f" ] && ! grep -q 'static const size_t page_size = 4096;' "$f"; then
  sed -i 's/^  static const size_t page_size = sysconf(_SC_PAGE_SIZE);$/#ifdef _WIN32\n  static const size_t page_size = 4096;\n#else\n  static const size_t page_size = sysconf(_SC_PAGE_SIZE);\n#endif/' "$f"
fi

# ART stl_util.h uses std::vector and std::unique_ptr without including them,
# relying on what the including file pulled in first; on older releases
# fd_file.cc reaches it without them under llvm-mingw's libc++.
f=src/art/libartbase/base/stl_util.h
if [ -f "$f" ] && ! grep -q '^#include <vector>' "$f"; then
  sed -i '0,/^#include <sstream>$/s//#include <memory>\n#include <sstream>\n#include <vector>/' "$f"
fi

# adb sysdeps.h (platform-tools-35.0.1 and earlier): the Windows fwrite ->
# adb_fwrite macro reaches libc++'s <print> (via logging.h's <ostream>) before
# it is included, turning std::fwrite into std::adb_fwrite. Include both first,
# as upstream later did.
f=$ADB/sysdeps.h
if [ -f "$f" ] && ! grep -q '^#include <print>' "$f"; then
  sed -i 's|^#include <android-base/utf8.h>$|#include <android-base/utf8.h>\n#include <android-base/logging.h>\n#if __has_include(<print>)\n#include <print>\n#endif|' "$f"
fi

# androidfw LoadedArsc.h (platform-tools-34.x): overlayable_infos_ is a vector
# of const pairs, which newer libc++ rejects; later releases dropped the const.
sed -i 's/std::vector<const std::pair<OverlayableInfo, std::unordered_set<uint32_t>>> overlayable_infos_;/std::vector<std::pair<OverlayableInfo, std::unordered_set<uint32_t>>> overlayable_infos_;/' \
  src/base/libs/androidfw/include/androidfw/LoadedArsc.h

# libusb NetBSD/OpenBSD: their backends finish transfers inside submit and
# can't cancel, which stalls and deadlocks older adb's async use of libusb.
# Queue bulk/interrupt transfers on per-endpoint workers instead
# (patches/sources/libusb_bsd_async.inc; the FreeBSD backend includes it).
for b in netbsd:netbsd obsd:openbsd; do
  f="src/libusb/libusb/os/${b#*:}_usb.c"; p="${b%%:*}"
  [ -f "$f" ] && grep -q "\.submit_transfer = ${p}_submit_transfer," "$f" || continue
  awk -v inc="$ROOTDIR/patches/sources/libusb_bsd_async.inc" -v p="$p" '
    { print }
    /^#include "libusbi.h"$/ { while ((getline l < inc) > 0) print l; close(inc) }
    END {
      print "#define SDK_AQ_SYNC_SUBMIT " p "_submit_transfer"
      print "#define SDK_AQ_SYNC_CANCEL " p "_cancel_transfer"
      print "#define SDK_AQ_SYNC_HANDLE " p "_handle_transfer_completion"
      print "#define SDK_AQ_IMPL"
      while ((getline l < inc) > 0) print l
    }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i -e "s/^\t\.submit_transfer = ${p}_submit_transfer,$/\t.submit_transfer = sdk_aq_submit,/" \
         -e "s/^\t\.cancel_transfer = ${p}_cancel_transfer,$/\t.cancel_transfer = sdk_aq_cancel,/" \
         -e "s/^\t\.handle_transfer_completion = ${p}_handle_transfer_completion,$/\t.handle_transfer_completion = sdk_aq_handle_completion,/" "$f"
done

# libusb netbsd_usb.c: size the devnode copy by its destination (both are
# 16 bytes today).
sed -i 's/strlcpy(dpriv->devnode, devnode, sizeof(devnode));/strlcpy(dpriv->devnode, devnode, sizeof(dpriv->devnode));/' \
  src/libusb/libusb/os/netbsd_usb.c

# libusb threads_posix.c (platform-tools-34 and earlier): OpenBSD's thread id
# via syscall(SYS_getthrid); OpenBSD no longer exposes syscall(). Newer libusb
# calls getthrid() directly.
sed -i 's/^\ttid = syscall(SYS_getthrid);$/\ttid = getthrid();/' src/libusb/libusb/os/threads_posix.c

# liblp super_layout_builder.cpp (older releases, still in system/core): uses
# std::sort without <algorithm>, which llvm-mingw's libc++ does not pull in.
for f in src/core/fs_mgr/liblp/super_layout_builder.cpp src/fs_mgr/liblp/super_layout_builder.cpp; do
  [ -f "$f" ] && ! grep -q '^#include <algorithm>' "$f" &&
    sed -i '0,/^#include <liblp\/super_layout_builder.h>$/s//#include <liblp\/super_layout_builder.h>\n\n#include <algorithm>/' "$f"
done

# adb sysdeps_win32.cpp (platform-tools-34 and earlier): a typedef named
# SetThreadDescription clashes with the function MinGW's headers declare.
# Cast to the pointer type inline instead, as later releases do.
sed -i -e '/^typedef HRESULT(WINAPI\* SetThreadDescription)(HANDLE hThread, PCWSTR lpThreadDescription);$/d' \
  -e 's/reinterpret_cast<SetThreadDescription>(/reinterpret_cast<HRESULT(WINAPI *)(HANDLE, PCWSTR)>(/' \
  $ADB/sysdeps_win32.cpp

# Older libcutils declares and defines its own gettid() unless glibc is 2.32+.
# glibc has had one since 2.30, and zig's glibc headers declare it (noexcept)
# whatever the target version. So leave it to glibc from 2.30, and below that
# match the header's declaration; the definition still supplies the symbol.
if [ -f src/core/libcutils/threads.cpp ]; then
  sed -i 's/defined(__GLIBC__) && __GLIBC_MINOR__ >= 32/defined(__GLIBC__) \&\& __GLIBC_MINOR__ >= 30/' \
    src/core/libcutils/threads.cpp
  sed -i 's/^pid_t gettid() {$/pid_t gettid()\n#if defined(__GLIBC__)\n__THROW\n#endif\n{/' \
    src/core/libcutils/threads.cpp
  sed -i -e 's/__GLIBC__ >= 2 && __GLIBC_MINOR__ < 32/__GLIBC__ >= 2 \&\& __GLIBC_MINOR__ < 30/' \
    -e 's/^extern pid_t gettid();$/#if defined(__GLIBC__)\nextern pid_t gettid() __THROW;\n#else\nextern pid_t gettid();\n#endif/' \
    src/core/libcutils/include/cutils/threads.h
fi

# Older libutils gives only glibc (not musl or the BSDs) the libbacktrace
# headers its CallStack.h includes; widen that block to not_windows.
sed -i '/^        linux_glibc: {$/{N;s/^        linux_glibc: {\n\(            header_libs: \["libbacktrace_headers"\],\)$/        not_windows: {\n\1/}' \
  src/core/libutils/Android.bp

# Older BoringSSL sizes its pthread CRYPTO_MUTEX by hand, too small for
# NetBSD's pthread_rwlock_t on some CPUs (thread_pthread.c static_asserts).
# Leave room; everything is linked statically, so the layout is private.
sed -i 's/^  uint8_t padding\[3\*sizeof(int) + 5\*sizeof(unsigned) + 16 + 8\];$/  uint8_t padding[3*sizeof(int) + 5*sizeof(unsigned) + 16 + 8 + 64];/' \
  src/boringssl/src/include/openssl/thread.h

# Older aidl's lexer expects bison to define YYSTYPE/YYLTYPE, which the
# glr.cc skeleton of newer bison doesn't; platform-tools-33.0.2 defines them.
if ! grep -q 'define YYSTYPE' src/aidl/aidl_language_l.ll; then
  sed -i 's/^#include "aidl_language_y.h"$/#include "aidl_language_y.h"\n\n#ifndef YYSTYPE\n#define YYSTYPE yy::parser::semantic_type\n#endif\n\n#ifndef YYLTYPE\n#define YYLTYPE yy::parser::location_type\n#endif/' \
    src/aidl/aidl_language_l.ll
fi

# Older ART safe_copy.cc takes PAGE_SIZE from <sys/user.h>, which not every
# libc/CPU defines (musl armeb, glibc loongarch64). Later ART uses its own
# kPageSize from globals.h; do the same.
if grep -q 'PAGE_SIZE' src/art/libartbase/base/safe_copy.cc; then
  sed -i -e 's/\bPAGE_SIZE\b/kPageSize/g' \
    -e 's/^#include "bit_utils.h"$/#include "bit_utils.h"\n#include "globals.h"/' \
    src/art/libartbase/base/safe_copy.cc
fi

# Older adb's Windows adb_iovec has a size_t iov_len, but it has to match
# WSABUF's 32-bit len (sysdeps_win32.cpp static_asserts it; 64-bit Windows
# fails). Later adb made it unsigned int.
sed -i 's/^    size_t iov_len;$/    unsigned int iov_len;/' $ADB/sysdeps/uio.h

# Older e2fsprogs ships a mingw unistd.h with its own getuid/geteuid/getgid/
# getegid stubs; host_compat.h already provides them on Windows.
[ -f src/e2fsprogs/include/mingw/unistd.h ] && \
  sed -i '/^__inline [_a-z]* get[e]\{0,1\}[ug]id(void){return [01];}$/d' \
    src/e2fsprogs/include/mingw/unistd.h

# Older libutils LruCache.h derives its functors from std::unary_function,
# which C++17 removed and newer libc++ drops; nothing uses the base.
sed -i 's/ : public std::unary_function<KeyedEntry\*, hash_t> {$/ {/' \
  src/core/libutils/include/utils/LruCache.h

# Older headers that use std::function without <functional> (newer libc++
# no longer pulls it in transitively). Add it ahead of their first #include <>.
for f in $ADB/adb_mdns.h src/core/fastboot/fastboot.h \
    $ADB/tls/include/adb/tls/tls_connection.h; do
  [ -f "$f" ] && grep -q 'std::function' "$f" && ! grep -q '<functional>' "$f" && \
    sed -i '0,/^#include </s//#include <functional>\n#include </' "$f"
done

# Older libziparchive builds a span from an ssize_t size, which narrows on
# 32-bit hosts.
sed -i 's/return {buf.first, ssize_t(buf.second)};/return {buf.first, size_t(buf.second)};/' \
  $ZIPARCHIVE/zip_archive.cc

# android-base/endian.h: insert a BSD branch (native <sys/endian.h>) so BSD
# doesn't fall into the macOS/Windows #else (<winsock2.h>, hard-coded LE).
python3 << 'PYEOF'
import sys

import os
path = os.environ['LIBBASE'] + '/include/android-base/endian.h'
with open(path, 'r') as f:
    content = f.read()

bsd_marker = '#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)'
if bsd_marker in content:
    print('endian.h BSD branch: already applied')
else:
    # Insert BSD elif between the glibc/musl block and the #else
    old = '#else\n\n#if defined(__APPLE__)'
    bsd_block = (
        '#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n'
        '\n'
        '/* BSD: sys/endian.h provides htobe16/32/64, htole16/32/64,\n'
        ' * be16/32/64toh, le16/32/64toh for the target arch;\n'
        ' * htons/htonl/ntohs/ntohl come from netinet/in.h. */\n'
        '#include <sys/endian.h>\n'
        '#include <netinet/in.h>\n'
        '\n'
        '/* BSD does not have glibc\'s 64-bit htonq/ntohq extensions. */\n'
        '#define htonq(x) htobe64(x)\n'
        '#define ntohq(x) be64toh(x)\n'
        '\n'
    )
    new = bsd_block + old
    if old in content:
        content = content.replace(old, new, 1)
        with open(path, 'w') as f:
            f.write(content)
        print('endian.h BSD branch inserted')
    else:
        print('endian.h: pattern not found', file=sys.stderr)
        sys.exit(1)
PYEOF

# e2fsprogs bitops.c: NetBSD declares popcount32() in <sys/bitops.h>, so guard
# the static re-declaration under #if !defined(__NetBSD__).
python3 << 'PYEOF'
import sys

path = 'src/e2fsprogs/lib/ext2fs/bitops.c'
with open(path, 'r') as f:
    content = f.read()

marker = 'static unsigned int popcount32(unsigned int w)'
if '#if !defined(__NetBSD__)' in content:
    print('popcount32 NetBSD guard: already applied')
elif marker in content:
    start = content.find(marker)
    # Walk forward to find the balanced closing brace of this function
    depth = 0
    i = start
    in_body = False
    while i < len(content):
        if content[i] == '{':
            depth += 1
            in_body = True
        elif content[i] == '}':
            depth -= 1
            if in_body and depth == 0:
                i += 1  # include the closing brace
                break
        i += 1
    func = content[start:i]
    guarded = '#if !defined(__NetBSD__)\n' + func + '\n#endif  /* !__NetBSD__ */'
    content = content[:start] + guarded + content[i:]
    with open(path, 'w') as f:
        f.write(content)
    print('popcount32 NetBSD guard applied')
else:
    print('popcount32: marker not found, skipping', file=sys.stderr)
PYEOF

# adb/sysdeps.h: add per-family branches to adb_thread_setname (OpenBSD
# pthread_set_name_np, NetBSD 3-arg, FreeBSD 2-arg).
python3 << 'PYEOF'
import sys

import os
path = os.environ['ADB'] + '/sysdeps.h'
with open(path, 'r') as f:
    content = f.read()

marker = '#elif defined(__OpenBSD__)\n    pthread_set_name_np(pthread_self(), name.c_str());'
if marker in content:
    print('adb/sysdeps.h BSD thread-name patch: already applied')
else:
    old = (
        '#ifdef __APPLE__\n'
        '    return pthread_setname_np(name.c_str());\n'
        '#else\n'
        '    // Both bionic and glibc\'s pthread_setname_np fails rather than truncating long strings.\n'
        '    // glibc doesn\'t have strlcpy, so we have to fake it.\n'
        '    char buf[16];  // MAX_TASK_COMM_LEN, but that\'s not exported by the kernel headers.\n'
        '    strncpy(buf, name.c_str(), sizeof(buf) - 1);\n'
        '    buf[sizeof(buf) - 1] = \'\\0\';\n'
        '    return pthread_setname_np(pthread_self(), buf);\n'
        '#endif\n'
    )
    new = (
        '#ifdef __APPLE__\n'
        '    return pthread_setname_np(name.c_str());\n'
        '#elif defined(__OpenBSD__)\n'
        '    pthread_set_name_np(pthread_self(), name.c_str());\n'
        '    return 0;\n'
        '#elif defined(__NetBSD__)\n'
        '    return pthread_setname_np(pthread_self(), "%s", (void*)name.c_str());\n'
        '#else\n'
        '    // Both bionic and glibc\'s pthread_setname_np fails rather than truncating long strings.\n'
        '    // glibc doesn\'t have strlcpy, so we have to fake it.\n'
        '    char buf[16];  // MAX_TASK_COMM_LEN, but that\'s not exported by the kernel headers.\n'
        '    strncpy(buf, name.c_str(), sizeof(buf) - 1);\n'
        '    buf[sizeof(buf) - 1] = \'\\0\';\n'
        '    return pthread_setname_np(pthread_self(), buf);\n'
        '#endif\n'
    )
    if old in content:
        content = content.replace(old, new, 1)
        with open(path, 'w') as f:
            f.write(content)
        print('adb/sysdeps.h BSD thread-name patch applied')
    else:
        print('adb/sysdeps.h: pattern not found, skipping', file=sys.stderr)
PYEOF

# --- termux-usb shims (android targets) -------------------------------------
# Route adb/fastboot USB enumeration through libtermuxadb. Inert unless
# LIBUSB_TERMUX_IMPL=1 at runtime.
case "$TARGET" in *-android|*-androideabi) TERMUX_OK=1 ;; *) TERMUX_OK=0 ;; esac
if [ "$TERMUX_OK" = 1 ]; then
  log "Applying termux-usb shims"
  cp "$ROOTDIR/patches/termux/termux_fastboot.h" "src/core/fastboot/termux_adb.h"

  ad=$ADB
  if [ -f "$ad/client/usb_linux.cpp" ]; then
    cp "$ROOTDIR/patches/termux/termux_adb.h" "$ad/client/termux_adb.h"

    # adb client/usb_linux.cpp: the /dev/bus/usb walk -> termuxadb:: shims.
    af="$ad/client/usb_linux.cpp"
    sed -i '/#include "sysdeps.h"/i #include "termux_adb.h"' "$af"
    sed -i \
      -e 's/opendir(base.c_str()), closedir/termuxadb::opendir(base.c_str()), termuxadb::closedir/' \
      -e 's/opendir(bus_name.c_str()), closedir/termuxadb::opendir(bus_name.c_str()), termuxadb::closedir/' \
      -e 's/readdir(bus_dir.get())/termuxadb::readdir(bus_dir.get())/' \
      -e 's/readdir(dev_dir.get())/termuxadb::readdir(dev_dir.get())/' \
      -e 's/unix_open(dev_name,/termuxadb::unix_open(dev_name,/' \
      -e 's/fd = unix_open(path, flags);/fd = termuxadb::unix_open(path, flags);/' \
      -e 's/unix_open(usb->path,/termuxadb::unix_open(usb->path,/' \
      -e 's/\bunix_close(fd)/termuxadb::unix_close(fd)/g' \
      -e 's/android::base::ReadFileToString(serial_path, &serial)/termuxadb::ReadFileToString(serial_path, \&serial)/' \
      "$af"

    # adb client/main.cpp: start the scanner (daemon path) + the sendfd helper mode.
    am="$ad/client/main.cpp"
    sed -i '/#include "commandline.h"/a #include "termux_adb.h"' "$am"
    sed -i '/setup_daemon_logging();/a\        termuxadb::start();' "$am"
    sed -i '/return adb_commandline/i\    if (termuxadb::sendfd()) { return 0; }' "$am"

    # adb from 35.0.1 on defaults to libusb on Linux, which bypasses
    # usb_linux.cpp and so the shims; keep the native backend while they are on.
    [ ! -f "$ad/client/transport_usb.cpp" ] || sed -i '/^bool \(is_libusb_enabled\|should_use_libusb\)() {/,/^}/ s/^    char\* env = getenv("ADB_LIBUSB");$/    if (const char* t = getenv("LIBUSB_TERMUX_IMPL"); t \&\& *t \&\& strcmp(t, "0") != 0) enable = false;\n&/' \
      "$ad/client/transport_usb.cpp"
  fi

  # fastboot main.cpp + fastboot.cpp: sendfd helper mode + scanner start.
  fm="src/core/fastboot/main.cpp"
  sed -i '/#include "fastboot.h"/a #include "termux_adb.h"' "$fm"
  sed -i '/int main(int argc, char\* argv\[\]) {/a\    if (termuxadb::sendfd()) { return 0; }' "$fm"
  ff="src/core/fastboot/fastboot.cpp"
  sed -i '/#include "fastboot.h"/a #include "termux_adb.h"' "$ff"
  sed -i '/int FastBootTool::Main(int argc, char\* argv\[\]) {/a\    termuxadb::start();' "$ff"

  # fastboot usb_linux.cpp: add find_usb_device_termux (/dev/bus/usb walk),
  # dispatched only when enabled(); stock sysfs find_usb_device stays for the off path.
  sed -i '/#include "usb.h"/a #include "termux_adb.h"' "src/core/fastboot/usb_linux.cpp"
  TERMUX_FB="src/core/fastboot/usb_linux.cpp" python3 << 'PYEOF'
import os, sys
path = os.environ['TERMUX_FB']
with open(path) as f: content = f.read()

if 'find_usb_device_termux' in content:
    print('termux fastboot: already applied'); sys.exit(0)
sig = 'static std::unique_ptr<usb_handle> find_usb_device(const char* base, ifc_match_func callback)'
start = content.find(sig)
if start == -1:
    print('termux fastboot: find_usb_device not found, skipping', file=sys.stderr); sys.exit(1)

termux_func = '''static std::unique_ptr<usb_handle> find_usb_device_termux(const char* base, ifc_match_func callback)
{
    std::unique_ptr<usb_handle> usb;
    char desc[1024];
    int n, in, out, ifc, cfg, alt_ifc;
    struct dirent* de;
    int fd;
    int writable;

    // termux: walk /dev/bus/usb/<bus>/<dev> via the shims (sysfs is unusable in
    // Termux without root).
    std::unique_ptr<DIR, int(*)(DIR*)> busdir(termuxadb::opendir(base), termuxadb::closedir);
    if (busdir == nullptr) return usb;

    while ((de = termuxadb::readdir(busdir.get())) && (usb == nullptr)) {
        if (badname(de->d_name)) continue;

        std::string bus_name = std::string(base) + "/" + de->d_name;
        std::unique_ptr<DIR, int(*)(DIR*)> devdir(termuxadb::opendir(bus_name.c_str()), termuxadb::closedir);
        if (devdir == nullptr) continue;

        struct dirent* de2;
        while ((de2 = termuxadb::readdir(devdir.get())) && (usb == nullptr)) {
            if (badname(de2->d_name)) continue;

            std::string dev_name = bus_name + "/" + de2->d_name;

            writable = 1;
            if ((fd = termuxadb::unix_open(dev_name.c_str(), O_RDWR)) < 0) {
                writable = 0;
                if ((fd = termuxadb::unix_open(dev_name.c_str(), O_RDONLY)) < 0) {
                    continue;
                }
            }

            n = read(fd, desc, sizeof(desc));

            if (filter_usb_device(de2->d_name, desc, n, writable, callback,
                                  &in, &out, &ifc, &cfg, &alt_ifc) == 0) {
                usb.reset(new usb_handle());
                strcpy(usb->fname, dev_name.c_str());
                usb->ep_in = in;
                usb->ep_out = out;
                usb->desc = fd;

                n = ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifc);
                if (n != 0) {
                    termuxadb::unix_close(fd);
                    usb.reset();
                    continue;
                }
                // Skip the sysfs bConfigurationValue recheck: de2->d_name is the
                // /dev devnum here, not a sysfs node.
                if (alt_ifc != 0) {
                    struct usbdevfs_setinterface set_ifc = {
                        .interface = (unsigned int)ifc,
                        .altsetting = (unsigned int)alt_ifc,
                    };
                    n = ioctl(fd, USBDEVFS_SETINTERFACE, &set_ifc);
                    if (n != 0) {
                        termuxadb::unix_close(fd);
                        usb.reset();
                        continue;
                    }
                }
            } else {
                termuxadb::unix_close(fd);
            }
        }
    }

    return usb;
}'''

# Older fastboot's filter_usb_device() has no cfg/alt_ifc out-parameters and
# never sets an alternate interface.
fdef = content.find('static int filter_usb_device(')
if fdef != -1 and 'alt' not in content[fdef:content.find(')', fdef)]:
    termux_func = termux_func.replace('int n, in, out, ifc, cfg, alt_ifc;', 'int n, in, out, ifc;')
    termux_func = termux_func.replace('&in, &out, &ifc, &cfg, &alt_ifc) == 0) {', '&in, &out, &ifc) == 0) {')
    a = termux_func.index('                // Skip the sysfs bConfigurationValue recheck')
    b = termux_func.index('            } else {')
    termux_func = termux_func[:a] + termux_func[b:]

content = content[:start] + termux_func + '\n\n' + content[start:]
content = content.replace(
    'find_usb_device("/sys/bus/usb/devices", callback)',
    'termuxadb::enabled()\n        ? find_usb_device_termux("/dev/bus/usb", callback)\n'
    '        : find_usb_device("/sys/bus/usb/devices", callback)',
    1)
with open(path, 'w') as f: f.write(content)
print('termux fastboot: find_usb_device_termux added + dispatch')
PYEOF
fi

if [ -z "$SKIPPED" ]; then
  log "Source fixups applied"
else
  log "Source fixups applied; not needed for this release (patch-source.sh lines):$SKIPPED"
fi
