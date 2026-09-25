#!/usr/bin/env bash
# In-place source fixups for the AOSP host-tool build.
#
#   ROOTDIR   checkout root (default: cwd)
#   TARGET    target triple; only the per-target sections look at it
#
# This is about the code only. Which files are compiled, with which flags, is
# the builder's business (builder/overlay/*.bp), and new source files the
# build adds live in patches/sources/ and are compiled from there.
#
# Best effort: the same script runs on every release the build supports, so a
# fixup whose code a release has changed (or does not have yet) is reported and
# skipped instead of failing the build. Run it once on a fresh checkout;
# re-running re-applies the seds.
set -Euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
TARGET="${TARGET:-}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

SKIPPED=0
trap 'SKIPPED=$((SKIPPED + 1)); printf "\033[1;33mwarning:\033[0m patch-source.sh:%s did not apply to these sources\n" "$LINENO" >&2' ERR

# A unified diff against the checkout (paths src/...); forward only, no .rej.
apply() { patch -p1 -N -s -r - --no-backup-if-mismatch -d "$ROOTDIR" -i "$1"; }

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
apply patches/misc/boringssl-getrandom-syscall.patch

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
sed -i '/^#include <variant>$/a #include <vector>' src/adb/fdevent/fdevent.h
sed -i '/^#include <algorithm>$/i #include <atomic>' src/adb/adb_mdns.cpp

# libbase posix_strerror_r.cpp: drop the file's #undef _GNU_SOURCE so the guard
# below sees the GNU char* strerror_r on glibc/bionic; musl keeps the #else.
sed -i '/\/\* Undefine _GNU_SOURCE/,/#undef _GNU_SOURCE/d' src/libbase/posix_strerror_r.cpp
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
#endif' src/libbase/posix_strerror_r.cpp

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

# e2fsprogs config.h: exclude _WIN32/BSD from HAVE_SYS_SYSMACROS_H (no such header).
sed -i 's/^#if !defined(__APPLE__)$/#if !defined(__APPLE__) \&\& !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  src/e2fsprogs/lib/config.h

# ADB Windows: default is_libusb_enabled() to the libusb backend (no AdbWinApi).
sed -i '/^bool is_libusb_enabled() {/,/^}/ s/#if defined(__APPLE__)/#if defined(__APPLE__) || defined(_WIN32) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)/' \
  src/adb/client/transport_usb.cpp

# ADB Windows+BSD: exclude the legacy native BlockingConnection USB path (dead,
# won't link), keeping is_adb_interface()/is_libusb_enabled().
sed -i '/^static int UsbReadMessage(usb_handle\* h, amessage\* msg) {/i #if !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)  // legacy native BlockingConnection USB path' \
  src/adb/client/transport_usb.cpp
sed -i '/^bool is_adb_interface(int usb_class/i #endif  // native USB path\n' \
  src/adb/client/transport_usb.cpp
# ...and the matching native-transport registration helpers in transport.cpp.
sed -i '/^void register_usb_transport(usb_handle\* usb,/i #if !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)  // native usb_handle transport registration' \
  src/adb/transport.cpp
sed -i '/^void unregister_usb_transport(usb_handle\* usb) {/,/^#endif/ { /^#endif/i #endif  // native USB path
}' src/adb/transport.cpp

# ADB Windows: make usb_libusb_hotplug.cpp's timeval time_t->long cast explicit.
sed -i 's/struct timeval timeout{(time_t)libusb_inhouse_hotplug::kScan_rate_s.count(), 0};/struct timeval timeout{static_cast<long>(libusb_inhouse_hotplug::kScan_rate_s.count()), 0};/' \
  src/adb/client/usb_libusb_hotplug.cpp

# ADB Windows: reinterpret_cast OSVERSIONINFO* to PRTL_OSVERSIONINFOW in sysdeps_win32.cpp.
sed -i 's/static_cast<PRTL_OSVERSIONINFOW>(&version)/reinterpret_cast<PRTL_OSVERSIONINFOW>(\&version)/' \
  src/adb/sysdeps_win32.cpp

# ADB Windows: reinterpret_cast adb_stat* to _stat64* for wstat() in stat.cpp.
sed -i 's/wstat(path_wide\.c_str(), &st)/wstat(path_wide.c_str(), reinterpret_cast<struct _stat64*>(\&st))/' \
  src/adb/sysdeps/win32/stat.cpp

# --- arm64ec (Windows) ------------------------------------------------------
# protobuf guards its x86 asm on __x86_64__ in several spellings -- plain
# "&& __GNUC__" (parse_context.h's ror/movb, port_def.inc's prefetcht0) and
# "__GCC_ASM_FLAG_OUTPUTS__ &&" (varint_shuffle.h's btc), which clang also defines
# on AArch64. arm64ec assembles none of it and every site has a portable #else, so
# require a non-EC target for the macro itself rather than per guard spelling.
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

# cacheflush(): ART's 32-bit ARM path calls it, and only bionic has it. glibc,
# musl and the BSDs export no cacheflush on ARM, so there it becomes the
# compiler runtime's __clear_cache (the cacheflush syscall on Linux,
# sysarch(ARM_SYNC_ICACHE) on the BSDs). mingw maps onto Win32
# FlushInstructionCache, declared by hand so <windows.h> stays behind utils.cc's
# own ERROR-macro dance.
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
sed -i '/^static_assert(std::is_same<std::underlying_type<log_id_t>::type, uint32_t>::value,$/i #ifndef __hexagon__' src/logging/liblog/logger_name.cpp
sed -i '/^static_assert(std::is_same<std::underlying_type<android_LogPriority>::type, uint32_t>::value,$/i #ifndef __hexagon__' src/logging/liblog/logger_name.cpp
sed -i '/^              "log_id_t must be an uint32_t");$/a #endif' src/logging/liblog/logger_name.cpp

# adb sysdeps/errno.cpp: guard out the ERRNO_VALUE static_asserts on MIPS (its
# errno numbers differ from the ADB wire values); the runtime switch still works.
sed -i 's@#define ERRNO_VALUE(error_name, wire_value) static_assert((error_name) == (wire_value), "")@#if !defined(__mips__)\n#define ERRNO_VALUE(error_name, wire_value) static_assert((error_name) == (wire_value), "")\n#else\n#define ERRNO_VALUE(error_name, wire_value) /* mips errno numbers differ from ADB wire values */\n#endif@' \
    src/adb/sysdeps/errno.cpp

# --- bionic below API 29 ------------------------------------------------------
# The bionic tools target API 24; these guard uses of API 29+ symbols.
sed -i 's/#if defined(__BIONIC__)/#if defined(__BIONIC__) \&\& __ANDROID_API__ >= 29/g' src/libbase/include/android-base/unique_fd.h src/libziparchive/zip_archive.cc src/art/libartbase/base/unix_file/fd_file.cc
sed -i 's/__INTRODUCED_IN([0-9]*)//g' src/logging/liblog/include/android/log.h src/adb/pairing_connection/include/adb/pairing/pairing_connection.h src/adb/pairing_auth/include/adb/pairing/pairing_auth.h
sed -i 's/^#if !defined(__BIONIC__)$/#if !defined(__BIONIC__) || __ANDROID_API__ < 29/' src/core/libcutils/native_handle.cpp
sed -i 's/^#ifdef __BIONIC__$/#if defined(__BIONIC__) \&\& __ANDROID_API__ >= 29/' src/core/libcutils/native_handle.cpp

# e2fsprogs error-table sources: rename the 'link' var (collides with POSIX
# link() on bionic) to 'et_link'.
for f in lib/support/prof_err.c lib/ext2fs/ext2_err.c; do
  sed -i 's/\blink\b/et_link/g' "src/e2fsprogs/$f"
done

# --- BSD --------------------------------------------------------------------
# Soong has no BSD target. These add BSD branches next to the Linux/macOS ones;
# the ones that only add #if'd code are applied for every target.
# libbase/threads.cpp GetThreadId() has no BSD branch, so it falls off a non-void
# function and clang's trap crashes adb at startup. Add the BSD calls + headers.
sed -i '/#include <unistd.h>/a\
#if defined(__FreeBSD__)\n#include <pthread_np.h>\n#elif defined(__NetBSD__)\n#include <lwp.h>\n#endif' src/libbase/threads.cpp
sed -i '/return syscall(__NR_gettid);/a\
#elif defined(__FreeBSD__)\n  return pthread_getthreadid_np();\n#elif defined(__NetBSD__)\n  return _lwp_self();\n#elif defined(__OpenBSD__)\n  return getthrid();' src/libbase/threads.cpp

# PosixUtils.cpp: 'stdout'/'stderr' locals are macros on BSD; rename to
# out_fd/err_fd.
case "$TARGET" in
  *-freebsd-*|*-netbsd-*|*-openbsd-*)
    sed -i \
      -e 's/int stdout\[2\]/int out_fd[2]/g' \
      -e 's/int stderr\[2\]/int err_fd[2]/g' \
      -e 's/pipe(stdout)/pipe(out_fd)/g' \
      -e 's/pipe(stderr)/pipe(err_fd)/g' \
      -e 's/stdout\[/out_fd[/g' \
      -e 's/stderr\[/err_fd[/g' \
      src/base/libs/androidfw/PosixUtils.cpp

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
if old3 in content:
    content = content.replace(old3, new3, 1)
    print('SetThreadName BSD elif patch applied')
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
  "src/libbase/include/android-base/off64_t.h"

# libbase file.cpp: GetExecutablePath() has no BSD branch.
sed -i 's/#elif defined(__EMSCRIPTEN__)/#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n  return getprogname();\n#elif defined(__EMSCRIPTEN__)/' \
  "src/libbase/file.cpp"

# libbase logging.cpp: the getprogname() fallback uses glibc-only
# program_invocation_short_name; BSDs have native getprogname().
sed -i 's/^#if !defined(__APPLE__) \&\& !defined(__BIONIC__)$/#if !defined(__APPLE__) \&\& !defined(__BIONIC__) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  "src/libbase/logging.cpp"

# libbase cmsg.cpp: <sys/user.h> is unused here and does not exist on NetBSD.
sed -i 's|#include <sys/user.h>|#if !defined(__NetBSD__)\n#include <sys/user.h>\n#endif|' \
  "src/libbase/cmsg.cpp"

# liblog logger_write.cpp: same getprogname() fallback issue.
sed -i 's/^#if !defined(__APPLE__) \&\& !defined(__BIONIC__)$/#if !defined(__APPLE__) \&\& !defined(__BIONIC__) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  "src/logging/liblog/logger_write.cpp"

# android-base/endian.h: insert a BSD branch (native <sys/endian.h>) so BSD
# doesn't fall into the macOS/Windows #else (<winsock2.h>, hard-coded LE).
python3 << 'PYEOF'
import sys

path = 'src/libbase/include/android-base/endian.h'
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

path = 'src/adb/sysdeps.h'
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
  cp "$ROOTDIR/patches/termux/termux_adb.h"      "src/adb/client/termux_adb.h"
  cp "$ROOTDIR/patches/termux/termux_fastboot.h" "src/core/fastboot/termux_adb.h"

  # adb client/usb_linux.cpp: the /dev/bus/usb walk -> termuxadb:: shims.
  af="src/adb/client/usb_linux.cpp"
  sed -i '/#include "sysdeps.h"/i #include "termux_adb.h"' "$af"
  sed -i \
    -e 's/opendir(base.c_str()), closedir/termuxadb::opendir(base.c_str()), termuxadb::closedir/' \
    -e 's/opendir(bus_name.c_str()), closedir/termuxadb::opendir(bus_name.c_str()), termuxadb::closedir/' \
    -e 's/readdir(bus_dir.get())/termuxadb::readdir(bus_dir.get())/' \
    -e 's/readdir(dev_dir.get())/termuxadb::readdir(dev_dir.get())/' \
    -e 's/unix_open(dev_name,/termuxadb::unix_open(dev_name,/' \
    -e 's/unix_open(usb->path,/termuxadb::unix_open(usb->path,/' \
    -e 's/\bunix_close(fd)/termuxadb::unix_close(fd)/g' \
    -e 's/android::base::ReadFileToString(serial_path, &serial)/termuxadb::ReadFileToString(serial_path, \&serial)/' \
    "$af"

  # adb client/main.cpp: start the scanner (daemon path) + the sendfd helper mode.
  am="src/adb/client/main.cpp"
  sed -i '/#include "commandline.h"/a #include "termux_adb.h"' "$am"
  sed -i '/setup_daemon_logging();/a\        termuxadb::start();' "$am"
  sed -i '/return adb_commandline/i\    if (termuxadb::sendfd()) { return 0; }' "$am"

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

if [ "$SKIPPED" -eq 0 ]; then
  log "Source fixups applied"
else
  log "Source fixups applied; $SKIPPED step(s) did not match these sources (see warnings)"
fi
