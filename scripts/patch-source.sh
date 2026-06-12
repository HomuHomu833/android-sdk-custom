#!/usr/bin/env bash
# In-place source fixups for the AOSP host-tool build.
#
#   ROOTDIR   checkout root (default: cwd)
#   TARGET    target triple; only the per-arch conditionals below look at it
#
# Raw in-place edits: run once on a fresh checkout (re-running may double-apply).
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
TARGET="${TARGET:-}"
PWD_SRC="$ROOTDIR"   # the old workflow anchored every path on ${PWD}
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- drop in the prebuilt patch files ---------------------------------------
log "Installing patch files"
mkdir -p src/incremental_delivery/sysprop/include
cp patches/misc/IncrementalProperties.sysprop.h   src/incremental_delivery/sysprop/include/
cp patches/misc/IncrementalProperties.sysprop.cpp src/incremental_delivery/sysprop/

cp patches/misc/deployagent.inc        src/adb/fastdeploy/deployagent/
cp patches/misc/deployagentscript.inc  src/adb/fastdeploy/deployagent/

# libusb-based fastboot USB backend: builds fastboot on windows without AdbWinApi
# (fastboot.cmake compiles this instead of usb_windows.cpp).
cp patches/misc/fastboot_usb_libusb.cpp src/core/fastboot/usb_libusb.cpp

# adb libusb-only Windows glue: supplies the usb_init()/usb_cleanup() entry points
# the dropped usb_windows.cpp (AdbWinApi, 32-bit) provided; LibUsbConnection does
# the I/O. adb.cmake compiles this on windows.
cp patches/misc/adb_usb_windows_libusb.cpp src/adb/client/usb_windows_libusb.cpp

# Windows <rpc.h> (via libbase <windows.h>) does `#define interface struct`, which
# clobbers usb_ifc_info's `interface` field; #undef it just before the struct.
sed -i '/^struct usb_ifc_info {/i\
#undef interface  /* Windows <rpc.h> defines this as `struct` */' src/core/fastboot/usb.h

cp patches/misc/platform_tools_version.h src/soong/cc/libbuildversion/include/

cp patches/misc/instruction_set.h        src/art/libartbase/arch/instruction_set.h
cp patches/misc/instruction_set.cc       src/art/libartbase/arch/instruction_set.cc
cp patches/misc/mem_map.h                src/art/libartbase/base/mem_map.h

cp patches/misc/target.h            src/boringssl/src/include/openssl/target.h
# getrandom_fillin.h moved between boringssl releases, so overwrite it wherever
# it lives.
find src/boringssl -name getrandom_fillin.h -exec cp patches/misc/getrandom_fillin.h {} \;

cp patches/misc/unscaledcycleclock.cc  src/abseil-cpp/absl/base/internal/unscaledcycleclock.cc

cp patches/misc/CombinedIterator.h  src/base/libs/androidfw/include/androidfw/CombinedIterator.h

# aapt2 proto include-path rewrites
sed -i 's#frameworks/base/tools/aapt2/Resources.proto#Resources.proto#g'         src/base/tools/aapt2/ApkInfo.proto
sed -i 's#frameworks/base/tools/aapt2/Configuration.proto#Configuration.proto#g'  src/base/tools/aapt2/Resources.proto
sed -i 's#frameworks/base/tools/aapt2/Configuration.proto#Configuration.proto#g'  src/base/tools/aapt2/ResourcesInternal.proto
sed -i 's#frameworks/base/tools/aapt2/Resources.proto#Resources.proto#g'          src/base/tools/aapt2/ResourcesInternal.proto

# point abseil at our in-tree googletest
sed -i 's#/usr/src/googletest#${CMAKE_SOURCE_DIR}/src/googletest#g' src/abseil-cpp/CMakeLists.txt

# boringssl pulls googletest from its own third_party dir
ln -sf "$ROOTDIR/src/googletest" "$ROOTDIR/src/boringssl/src/third_party/googletest"

log "Applying source fixups${TARGET:+ for $TARGET}"

# PAGE_SIZE: all-platform #ifndef fallback (can't assume it in the 16K-page era).
# (TEMP_FAILURE_RETRY comes from host_compat.h on the hosts that lack it.)
sed -i '/};/ a\
#ifndef PAGE_SIZE\
#define PAGE_SIZE 4096\
#endif' ${PWD_SRC}/src/logging/liblog/logger.h

sed -i '/struct msghdr hdr = {/,/};/c\
    struct msghdr hdr = {};\
    hdr.msg_name = &addr;\
    hdr.msg_namelen = sizeof(addr);\
    hdr.msg_iov = &iov;\
    hdr.msg_iovlen = 1;\
    hdr.msg_control = static_cast<void*>(control);\
    hdr.msg_controllen = sizeof(control);
' ${PWD_SRC}/src/core/libcutils/uevent.cpp

find ${PWD_SRC}/src -type f \( -name "*.c" -o -name "*.cpp" -o -name "*.h" \) -exec sed -i '/#include <sys\/cdefs.h>/c\
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\
#include <sys/cdefs.h>\
#else\
#ifdef __cplusplus\
#ifndef __GLIBC__\
#define __BEGIN_DECLS extern "C" {\
#define __END_DECLS }\
#endif\
#else\
#ifndef __GLIBC__\
#define __BEGIN_DECLS\
#define __END_DECLS\
#endif\
#endif\
#ifndef __INTRODUCED_IN\
#define __INTRODUCED_IN(version)\
#endif\
#endif' {} +

# packagelistparser.h uses __BEGIN_DECLS/__END_DECLS from <sys/cdefs.h>; expand
# them inline where that header is absent. BSD keeps its own, so skip there.
case "$TARGET" in
  *-freebsd-*|*-netbsd-*|*-openbsd-*) ;;
  *)
    sed -i 's/__BEGIN_DECLS/#ifdef __cplusplus\nextern "C" {\n#endif/g; s/__END_DECLS/#ifdef __cplusplus\n}\n#endif/g' ${PWD_SRC}/src/core/libpackagelistparser/include/packagelistparser/packagelistparser.h
    ;;
esac

sed -i '/#include <sys\/limits.h>/d; /#include <log\/log.h>/a\
#ifndef GID_MAX\n#define GID_MAX 2147483647\n#endif\n\
#ifndef UID_MAX\n#define UID_MAX 2147483647\n#endif' ${PWD_SRC}/src/core/libpackagelistparser/packagelistparser.cpp

sed -i 's/std::vector<const StringPiece>/std::vector<StringPiece>/g' ${PWD_SRC}/src/base/tools/aapt2/util/Files.cpp

# fmtlib's allocator calls bare malloc()/free() via <cstdlib> leaking the C names
# globally; zig 0.17's libc++ doesn't, so pull in <stdlib.h> after the guard.
sed -i '/#define FMT_FORMAT_H_/a #include <stdlib.h>' ${PWD_SRC}/src/fmtlib/include/fmt/format.h

# riscv32/powerpc: drop the std::atomic is_always_lock_free static_assert (not
# always lock-free there).
case "$TARGET" in
  riscv32-*|powerpc-*)
    sed -i 's/^\([[:space:]]*\)static_assert(std::atomic<.*>::is_always_lock_free);/\1\/\/ &/' ${PWD_SRC}/src/art/libartbase/base/metrics/metrics.h
    ;;
esac

# cacheflush()/<sys/cachectl.h> is used only in utils.cc's __arm__ branch. zig's
# generic-glibc header pulls <asm/cachectl.h> which zig doesn't ship, so on glibc
# forward-declare cacheflush; musl's header is self-contained, so keep it there.
sed -i '/#include "os.h"/a\
#if defined(__arm__)\
#if defined(__GLIBC__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\
extern "C" int cacheflush(void*, int, int);\
#else\
#include <sys/cachectl.h>\
#endif\
#endif' ${PWD_SRC}/src/art/libartbase/base/utils.cc
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
}' ${PWD_SRC}/src/art/libartbase/base/utils.cc
sed -i '/FlushCpuCaches/,/}/ {
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/i #if !defined(__s390x__) && !defined(__ppc__) && !defined(__hexagon__)
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/a #endif
}' ${PWD_SRC}/src/art/libartbase/base/utils.cc

sed -i '/#if __has_feature(cxx_exceptions)/,/^#endif/ c\using Task = std::packaged_task<void()>;' ${PWD_SRC}/src/openscreen/platform/api/task_runner.h

# dex_file.cc: add the missing operator<< for EncodedArrayValueIterator::ValueType.
sed -i '/^dex::ProtoIndex DexFile::GetProtoIndexForCallSite(uint32_t call_site_idx) const {/,/^.*}[[:space:]]*$/ {
  /^.*}[[:space:]]*$/ s/$/ \/\/__INSERT_HERE__/
}' ${PWD_SRC}/src/art/libdexfile/dex/dex_file.cc
sed -i '/\/\/__INSERT_HERE__/a\
\
std::ostream& operator<<(std::ostream& os, EncodedArrayValueIterator::ValueType rhs) {\
  switch (rhs) {\
    case EncodedArrayValueIterator::kByte: os << "Byte"; break;\
    case EncodedArrayValueIterator::kShort: os << "Short"; break;\
    case EncodedArrayValueIterator::kChar: os << "Char"; break;\
    case EncodedArrayValueIterator::kInt: os << "Int"; break;\
    case EncodedArrayValueIterator::kLong: os << "Long"; break;\
    case EncodedArrayValueIterator::kFloat: os << "Float"; break;\
    case EncodedArrayValueIterator::kDouble: os << "Double"; break;\
    case EncodedArrayValueIterator::kMethodType: os << "MethodType"; break;\
    case EncodedArrayValueIterator::kMethodHandle: os << "MethodHandle"; break;\
    case EncodedArrayValueIterator::kString: os << "String"; break;\
    case EncodedArrayValueIterator::kType: os << "Type"; break;\
    case EncodedArrayValueIterator::kField: os << "Field"; break;\
    case EncodedArrayValueIterator::kMethod: os << "Method"; break;\
    case EncodedArrayValueIterator::kEnum: os << "Enum"; break;\
    case EncodedArrayValueIterator::kArray: os << "Array"; break;\
    case EncodedArrayValueIterator::kAnnotation: os << "Annotation"; break;\
    case EncodedArrayValueIterator::kNull: os << "Null"; break;\
    case EncodedArrayValueIterator::kBoolean: os << "Boolean"; break;\
    default: os << "EncodedArrayValueIterator::ValueType[" << static_cast<int>(rhs) << "]"; break;\
  }\
  return os;\
}\
' ${PWD_SRC}/src/art/libdexfile/dex/dex_file.cc
sed -i 's/ \/\/__INSERT_HERE__//' ${PWD_SRC}/src/art/libdexfile/dex/dex_file.cc

sed -i "s/SOONG BUILD NUMBER PLACEHOLDER/$(date +%y%m%d%H%M%S)/" ${PWD_SRC}/src/soong/cc/libbuildversion/libbuildversion.cpp
sed -i 's/set(CMAKE_CXX_STANDARD *14)/set(CMAKE_CXX_STANDARD 17)/' src/boringssl/CMakeLists.txt
sed -i '/packLocale/s/constexpr //;/packScript/s/constexpr //' src/base/libs/androidfw/include/androidfw/LocaleDataLookup.h
sed -i '/utf8.resize_and_overwrite/{N;N;N; s/utf8.resize_and_overwrite(utf8_length,.*{[^}]*});/utf8.resize(utf8_length);\n  utf16_to_utf8(utf16.data(), utf16.length(), utf8.data(), utf8_length + 1);/}' src/base/libs/androidfw/Util.cpp
sed -i 's/libusb::usb_init();/usb_init();/g' ${PWD_SRC}/src/adb/client/main.cpp
sed -i 's/path_data\.name\.contains('\''\.'\'')/path_data.name.find('\''.'\'') != std::string::npos/g' src/base/tools/aapt2/cmd/Compile.cpp

# libbase posix_strerror_r.cpp: on gnu, strl_compat.h pulls <string.h> with
# _GNU_SOURCE so strerror_r is the GNU char* variant; the file's #undef _GNU_SOURCE
# would defeat the guard below, so drop it first. musl (no -D_GNU_SOURCE) keeps the
# #else; bionic also has the char* variant under _GNU_SOURCE, joining that branch.
sed -i '/\/\* Undefine _GNU_SOURCE/,/#undef _GNU_SOURCE/d' ${PWD_SRC}/src/libbase/posix_strerror_r.cpp
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
#endif' ${PWD_SRC}/src/libbase/posix_strerror_r.cpp

# abseil ppc32 stacktrace: glibc reads regs via uc_mcontext.uc_regs->gregs[]
# (uc_regs is a pt_regs*), but musl exposes them directly as uc_mcontext.gregs[].
# Rewrite for musl ppc32 only; glibc ppc32 keeps the uc_regs-> form.
case "$TARGET" in
  powerpc-*musl*)
    for f in src/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc \
             src/abseil-cpp/absl/debugging/internal/examine_stack.cc; do
      [ -f "$f" ] && sed -i 's/uc_mcontext\.uc_regs->gregs/uc_mcontext.gregs/g' "$f"
    done
    ;;
esac

# abseil direct_mmap.h static_asserts "no __NR_mmap2 => 64-bit", wrong for the
# generic-syscall 32-bit arches (riscv32, hexagon). Replace just the assert with a
# libc mmap() fallback on non-LP64; the LP64 64-bit syscall path is left intact.
sed -i 's@^\([[:space:]]*\)static_assert(sizeof(unsigned long) == 8, "Platform is not 64-bit");@#if !defined(__LP64__)\n\1return mmap(start, length, prot, flags, fd, offset);\n#endif@' \
  "${PWD_SRC}/src/abseil-cpp/absl/base/internal/direct_mmap.h"

# abseil examine_stack.cc: add hexagon to GetProgramCounter() (musl's mcontext_t
# is struct sigcontext with a .pc field) by inserting a case before #else/#error.
sed -i '/^#else$/{N;s/^#else\n#error "Undefined Architecture."/#elif defined(__hexagon__)\n    return reinterpret_cast<void*>(context->uc_mcontext.pc);\n#else\n#error "Undefined Architecture."/;}' \
  "${PWD_SRC}/src/abseil-cpp/absl/debugging/internal/examine_stack.cc"

# abseil conditions.h: the Win32 guard wrongly excluded hexagon, leaving _exit
# undeclared; drop hexagon from it (<unistd.h> then declares _exit on hexagon musl).
sed -i 's/^#if defined(_WIN32) || defined(__hexagon__)$/#if defined(_WIN32)/' \
  "${PWD_SRC}/src/abseil-cpp/absl/log/internal/conditions.h"

# liblog logger_name.cpp: hexagon Clang makes android_LogPriority's underlying type
# unsigned char, tripping the uint32_t static_assert. Guard both asserts under
# !__hexagon__ (they're only ABI-relevant on-device).
sed -i '/^static_assert(std::is_same<std::underlying_type<log_id_t>::type, uint32_t>::value,$/i #ifndef __hexagon__' ${PWD_SRC}/src/logging/liblog/logger_name.cpp
sed -i '/^static_assert(std::is_same<std::underlying_type<android_LogPriority>::type, uint32_t>::value,$/i #ifndef __hexagon__' ${PWD_SRC}/src/logging/liblog/logger_name.cpp
sed -i '/^              "log_id_t must be an uint32_t");$/a #endif' ${PWD_SRC}/src/logging/liblog/logger_name.cpp

# selinux libsepol cil_verify.c: struct field is uint32_t* but local is
# enum cil_flavor — Clang (unlike GCC) rejects the implicit conversion in C.
sed -i 's/extra_args\.flavor = \&flavor;/extra_args.flavor = (uint32_t *)\&flavor;/' \
  ${PWD_SRC}/src/selinux/libsepol/cil/src/cil_verify.c

# selinux selinux_internal.h __selinux_once: the integer-pthread_once_t fallback
# fails on macOS/mingw (struct there). pthread_once always exists on those hosts,
# so call it directly.
sed -i '/#define __selinux_once(ONCE_CONTROL, INIT_FUNCTION)/i\
#if defined(__APPLE__) || defined(_WIN32)\
#define __selinux_once(ONCE_CONTROL, INIT_FUNCTION) \\\
	pthread_once(\&(ONCE_CONTROL), (INIT_FUNCTION))\
#else' ${PWD_SRC}/src/selinux/libselinux/src/selinux_internal.h
sed -i '0,/} while (0)/s/} while (0)/} while (0)\
#endif/' ${PWD_SRC}/src/selinux/libselinux/src/selinux_internal.h

# bionic: some symbols are API 29+, but we may target lower APIs. Guard their uses
# behind an API check.
sed -i 's/#if defined(__BIONIC__)/#if defined(__BIONIC__) \&\& __ANDROID_API__ >= 29/g' ${PWD_SRC}/src/libbase/include/android-base/unique_fd.h ${PWD_SRC}/src/libziparchive/zip_archive.cc src/art/libartbase/base/unix_file/fd_file.cc
sed -i 's/__INTRODUCED_IN([0-9]*)//g' ${PWD_SRC}/src/logging/liblog/include/android/log.h ${PWD_SRC}/src/adb/pairing_connection/include/adb/pairing/pairing_connection.h ${PWD_SRC}/src/adb/pairing_auth/include/adb/pairing/pairing_auth.h
sed -i 's/^#if !defined(__BIONIC__)$/#if !defined(__BIONIC__) || __ANDROID_API__ < 29/' ${PWD_SRC}/src/core/libcutils/native_handle.cpp
sed -i 's/^#ifdef __BIONIC__$/#if defined(__BIONIC__) \&\& __ANDROID_API__ >= 29/' ${PWD_SRC}/src/core/libcutils/native_handle.cpp

# PosixUtils.cpp ExecuteBinary() uses 'stdout'/'stderr' as locals, but on BSD
# those are macros, so `int stdout[2]` is invalid. Rename to out_fd/err_fd
# (result.stdout_str is a member access and unaffected).
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

    # utils.cc: GetTid() falls to Linux-only syscall(__NR_gettid); add a BSD branch
    # (pthread_self -> uint32_t). SetThreadName()'s linux/win guard misses BSD:
    # FreeBSD has Linux's 2-arg setname_np, NetBSD a 3-arg form, OpenBSD none.
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

# brotli: restore static-library support
( cd ${PWD_SRC}/src/brotli && git apply ../../patches/0001-add-static-support-back-to-brotli.patch )

# selinux: guard host-inert Linux-isms in libselinux (selinuxfs/proc probe,
# __fsetlocking, O_CLOEXEC, stpcpy, getxattr) so macOS/mingw compile. See patches/selinux/.
( cd ${PWD_SRC}/src/selinux && git apply ../../patches/selinux/0001-host-portability-guards.patch )

# setrans_client.c: POSIX socket headers don't exist on MinGW; with DISABLE_SETRANS
# the bodies are stubs, so the network includes are dead code. Guard them out.
sed -i '/^#include <netdb.h>/i #ifndef _WIN32' ${PWD_SRC}/src/selinux/libselinux/src/setrans_client.c
sed -i '/^#include <sys\/uio.h>/a #endif' ${PWD_SRC}/src/selinux/libselinux/src/setrans_client.c

# e2fsprogs error-table sources: the 'link' var collides with POSIX link() on
# bionic; rename to 'et_link' in the files defining static struct et_list link.
for f in lib/support/prof_err.c lib/ext2fs/ext2_err.c lib/ss/ss_err.c; do
  sed -i 's/\blink\b/et_link/g' "${PWD_SRC}/src/e2fsprogs/$f"
done

# e2fsprogs config.h hard-codes HAVE_SYS_SYSMACROS_H, but llvm-mingw ships none;
# exclude _WIN32 (and the BSDs) from the define (devname.c guards the include on
# it). makedev() comes from host_compat.h on Windows.
sed -i 's/^#if !defined(__APPLE__)$/#if !defined(__APPLE__) \&\& !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  ${PWD_SRC}/src/e2fsprogs/lib/config.h

# MinGW on case-sensitive Linux: <Ws2tcpip.h> won't match ws2tcpip.h
sed -i 's/#include\t<Ws2tcpip.h>/#include\t<ws2tcpip.h>/' \
  ${PWD_SRC}/src/mdnsresponder/mDNSShared/CommonServices.h

# ADB Windows: default to the libusb backend (no native AdbWinApi backend). Only
# is_libusb_enabled()'s body is touched, leaving the __APPLE__ overflow guard alone.
sed -i '/^bool is_libusb_enabled() {/,/^}/ s/#if defined(__APPLE__)/#if defined(__APPLE__) || defined(_WIN32) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)/' \
  ${PWD_SRC}/src/adb/client/transport_usb.cpp

# ADB Windows+BSD: the legacy BlockingConnection USB path (UsbConnection, free
# usb_read/write helpers, init_usb_transport) belongs to the native backends we
# don't build here; it's dead and won't link. Exclude it, keeping only
# is_adb_interface()/is_libusb_enabled().
sed -i '/^static int UsbReadMessage(usb_handle\* h, amessage\* msg) {/i #if !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)  // legacy native BlockingConnection USB path' \
  ${PWD_SRC}/src/adb/client/transport_usb.cpp
sed -i '/^bool is_adb_interface(int usb_class/i #endif  // native USB path\n' \
  ${PWD_SRC}/src/adb/client/transport_usb.cpp
# ...and the matching native-transport registration helpers in transport.cpp
# (register_usb_transport calls the now-absent init_usb_transport).
sed -i '/^void register_usb_transport(usb_handle\* usb,/i #if !defined(_WIN32) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)  // native usb_handle transport registration' \
  ${PWD_SRC}/src/adb/transport.cpp
sed -i '/^void unregister_usb_transport(usb_handle\* usb) {/,/^#endif/ { /^#endif/i #endif  // native USB path
}' ${PWD_SRC}/src/adb/transport.cpp

# ADB Windows: usb_libusb_hotplug.cpp's timeval init narrows time_t->long, which
# clang rejects; make the cast explicit.
sed -i 's/struct timeval timeout{(time_t)libusb_inhouse_hotplug::kScan_rate_s.count(), 0};/struct timeval timeout{static_cast<long>(libusb_inhouse_hotplug::kScan_rate_s.count()), 0};/' \
  ${PWD_SRC}/src/adb/client/usb_libusb_hotplug.cpp

# ADB Windows: sysdeps_win32.cpp casts between distinct structs OSVERSIONINFO and
# RTL_OSVERSIONINFOW; use reinterpret_cast.
sed -i 's/static_cast<PRTL_OSVERSIONINFOW>(&version)/reinterpret_cast<PRTL_OSVERSIONINFOW>(\&version)/' \
  ${PWD_SRC}/src/adb/sysdeps_win32.cpp

# ADB Windows: stat.cpp passes struct adb_stat* where wstat (_wstat64) wants
# struct _stat64*; reinterpret_cast it.
sed -i 's/wstat(path_wide\.c_str(), &st)/wstat(path_wide.c_str(), reinterpret_cast<struct _stat64*>(\&st))/' \
  ${PWD_SRC}/src/adb/sysdeps/win32/stat.cpp

# gtest-port.cc: on FreeBSD AArch64 <machine/proc.h>'s struct ptrauth_key clashes
# with clang's builtin ptrauth typedef; guard the include and stub GetThreadCount().
sed -i '/^#include <sys\/user.h>$/i #if !defined(__FreeBSD__) || !defined(__aarch64__)' \
  "${PWD_SRC}/src/googletest/googletest/src/gtest-port.cc"
sed -i '/^#include <sys\/user.h>$/a #endif' \
  "${PWD_SRC}/src/googletest/googletest/src/gtest-port.cc"
sed -i '/#elif defined(GTEST_OS_DRAGONFLY) || defined(GTEST_OS_FREEBSD) || \\$/{
  N
  s/#elif defined(GTEST_OS_DRAGONFLY) || defined(GTEST_OS_FREEBSD) || \\\n    defined(GTEST_OS_GNU_KFREEBSD) || defined(GTEST_OS_NETBSD)/#elif defined(GTEST_OS_FREEBSD) \&\& defined(__aarch64__)\nsize_t GetThreadCount() { return 0; }\n#elif defined(GTEST_OS_DRAGONFLY) || defined(GTEST_OS_FREEBSD) || \\\n    defined(GTEST_OS_GNU_KFREEBSD) || defined(GTEST_OS_NETBSD)/
}' "${PWD_SRC}/src/googletest/googletest/src/gtest-port.cc"

# abseil stacktrace.cc: NetBSD/OpenBSD declare alloca() as a function (not a macro),
# so the #if !defined(alloca) guard misses it and the static def conflicts. Guard it.
sed -i '/static void\* alloca(size_t) noexcept { return nullptr; }/i #if !defined(__NetBSD__) \&\& !defined(__OpenBSD__)' \
  "${PWD_SRC}/src/abseil-cpp/absl/debugging/stacktrace.cc"
sed -i '/static void\* alloca(size_t) noexcept { return nullptr; }/a #endif' \
  "${PWD_SRC}/src/abseil-cpp/absl/debugging/stacktrace.cc"

# off64_t.h: BSDs don't have a separate off64_t type (off_t is always 64-bit).
sed -i 's/^#if defined(__APPLE__)$/#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)/' \
  "${PWD_SRC}/src/libbase/include/android-base/off64_t.h"

# libbase file.cpp: GetExecutablePath() has no BSD branch.
sed -i 's/#elif defined(__EMSCRIPTEN__)/#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)\n  return getprogname();\n#elif defined(__EMSCRIPTEN__)/' \
  "${PWD_SRC}/src/libbase/file.cpp"

# libbase logging.cpp: the getprogname() fallback uses program_invocation_short_name
# which is glibc-only. FreeBSD/NetBSD/OpenBSD have native getprogname().
sed -i 's/^#if !defined(__APPLE__) \&\& !defined(__BIONIC__)$/#if !defined(__APPLE__) \&\& !defined(__BIONIC__) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  "${PWD_SRC}/src/libbase/logging.cpp"

# libbase cmsg.cpp: <sys/user.h> is unused here and does not exist on NetBSD.
sed -i 's|#include <sys/user.h>|#if !defined(__NetBSD__)\n#include <sys/user.h>\n#endif|' \
  "${PWD_SRC}/src/libbase/cmsg.cpp"

# liblog logger_write.cpp: same getprogname() fallback issue.
sed -i 's/^#if !defined(__APPLE__) \&\& !defined(__BIONIC__)$/#if !defined(__APPLE__) \&\& !defined(__BIONIC__) \&\& !defined(__FreeBSD__) \&\& !defined(__NetBSD__) \&\& !defined(__OpenBSD__)/' \
  "${PWD_SRC}/src/logging/liblog/logger_write.cpp"

# android-base/endian.h: BSD falls into the macOS/Windows #else (no __BIONIC__/
# __GLIBC__/ANDROID_HOST_MUSL), which includes <winsock2.h> and hard-codes
# little-endian. Insert a BSD branch using the native <sys/endian.h>.
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

# e2fsprogs bitops.c: NetBSD declares popcount32() non-statically (<sys/bitops.h>),
# so bitops.c's static re-declaration errors. Guard the inline fallback with
# #if !defined(__NetBSD__).
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

# adb/sysdeps.h: adb_thread_setname hits the 2-arg pthread_setname_np #else; BSD
# APIs differ — OpenBSD pthread_set_name_np (void), NetBSD 3-arg printf-style,
# FreeBSD GNU-compatible 2-arg. Add per-family branches.
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

# boringssl cpu_aarch64_openbsd.cc: only OpenBSD gets OPENSSL_cpuid_setup; append a
# FreeBSD/NetBSD aarch64 impl via elf_aux_info when <sys/auxv.h> exists (else empty
# body). The block #includes internal.h itself (OPENSSL_armcap_P/ARMV*) since the
# file only includes it inside the OpenBSD block.
python3 << 'PYEOF'
import sys

path = 'src/boringssl/src/crypto/cpu_aarch64_openbsd.cc'
with open(path, 'r') as f:
    content = f.read()

marker = '// NetBSD/FreeBSD aarch64 cpuid'
if marker in content:
    print('cpu_aarch64_openbsd.cc BSD cpuid: already applied')
else:
    stub = r"""
// NetBSD/FreeBSD aarch64 CPU feature detection via elf_aux_info.
// Both OSes expose the ELF auxiliary vector through elf_aux_info() in
// <sys/auxv.h> when the sysroot is new enough (FreeBSD 12+, NetBSD 10+).
// internal.h (included below) provides OPENSSL_armcap_P, ARMV7_NEON/ARMV8_*,
// and the declaration of OPENSSL_cpuid_setup.  In AOSP BoringSSL the function
// has C linkage so it must be defined as plain void OPENSSL_cpuid_setup(void).
#if defined(OPENSSL_AARCH64) && !defined(OPENSSL_OPENBSD) && \
    (defined(__NetBSD__) || defined(__FreeBSD__)) && \
    !defined(OPENSSL_STATIC_ARMCAP) && !defined(OPENSSL_NO_ASM)
#include "internal.h"
#if __has_include(<sys/auxv.h>)
#include <sys/auxv.h>

void OPENSSL_cpuid_setup(void) {
  unsigned long hwcap = 0;
  elf_aux_info(AT_HWCAP, &hwcap, sizeof(hwcap));
  if (!(hwcap & (1UL << 1))) {  // ASIMD/NEON
    return;
  }
  OPENSSL_armcap_P |= ARMV7_NEON;
  if (hwcap & (1UL << 3))  OPENSSL_armcap_P |= ARMV8_AES;
  if (hwcap & (1UL << 4))  OPENSSL_armcap_P |= ARMV8_PMULL;
  if (hwcap & (1UL << 5))  OPENSSL_armcap_P |= ARMV8_SHA1;
  if (hwcap & (1UL << 6))  OPENSSL_armcap_P |= ARMV8_SHA256;
  if (hwcap & (1UL << 21)) OPENSSL_armcap_P |= ARMV8_SHA512;
}
#else
// <sys/auxv.h> is absent from this sysroot (older NetBSD); no hardware
// crypto features will be detected.  Safe: BoringSSL falls back to software.
void OPENSSL_cpuid_setup(void) {}
#endif  // __has_include(<sys/auxv.h>)
#endif  // NetBSD/FreeBSD aarch64 cpuid
"""
    content += stub
    with open(path, 'w') as f:
        f.write(content)
    print('cpu_aarch64_openbsd.cc BSD cpuid appended')
PYEOF

# boringssl cpu_arm_freebsd.cc: only FreeBSD ARM32 gets OPENSSL_cpuid_setup; append
# a NetBSD/OpenBSD ARM32 impl via elf_aux_info when <sys/auxv.h> exists (else an
# empty body so the build still succeeds).
python3 << 'PYEOF'
import sys

path = 'src/boringssl/src/crypto/cpu_arm_freebsd.cc'
with open(path, 'r') as f:
    content = f.read()

marker = '// NetBSD/OpenBSD ARM 32-bit cpuid'
if marker in content:
    print('cpu_arm_freebsd.cc BSD cpuid: already applied')
else:
    stub = r"""
// NetBSD/OpenBSD ARM 32-bit CPU feature detection via elf_aux_info.
// cpu_arm_freebsd.cc already provides OPENSSL_cpuid_setup for FreeBSD ARM32
// using elf_aux_info(AT_HWCAP, ...) / elf_aux_info(AT_HWCAP2, ...).
// NetBSD and OpenBSD expose the same interface when the sysroot is new enough
// (NetBSD 10+, OpenBSD 5.6+).  Use __has_include to compile the real
// implementation only when <sys/auxv.h> is present; older sysroots fall back.
// internal.h is #included at the top of this file, so OPENSSL_armcap_P and
// ARMV7_NEON/ARMV8_* are available in the bssl namespace.
#if !defined(OPENSSL_NO_ASM) && defined(OPENSSL_ARM) && \
    !defined(OPENSSL_FREEBSD) && !defined(OPENSSL_STATIC_ARMCAP) && \
    (defined(__NetBSD__) || defined(__OpenBSD__))
#if __has_include(<sys/auxv.h>)
#include <sys/auxv.h>

// ARM 32-bit HWCAP bits — inline constants matching cpu_arm_freebsd.cc style.
#ifndef HWCAP_NEON
# define HWCAP_NEON   (1UL << 12)
#endif
#ifndef HWCAP2_AES
# define HWCAP2_AES   (1UL << 0)
#endif
#ifndef HWCAP2_PMULL
# define HWCAP2_PMULL (1UL << 1)
#endif
#ifndef HWCAP2_SHA1
# define HWCAP2_SHA1  (1UL << 2)
#endif
#ifndef HWCAP2_SHA2
# define HWCAP2_SHA2  (1UL << 3)
#endif

void OPENSSL_cpuid_setup(void) {
  unsigned long hwcap = 0, hwcap2 = 0;
  elf_aux_info(AT_HWCAP, &hwcap, sizeof(hwcap));
  elf_aux_info(AT_HWCAP2, &hwcap2, sizeof(hwcap2));
  if (hwcap & HWCAP_NEON) {
    OPENSSL_armcap_P |= ARMV7_NEON;
    if (hwcap2 & HWCAP2_AES)   OPENSSL_armcap_P |= ARMV8_AES;
    if (hwcap2 & HWCAP2_PMULL) OPENSSL_armcap_P |= ARMV8_PMULL;
    if (hwcap2 & HWCAP2_SHA1)  OPENSSL_armcap_P |= ARMV8_SHA1;
    if (hwcap2 & HWCAP2_SHA2)  OPENSSL_armcap_P |= ARMV8_SHA256;
  }
}
#else
// <sys/auxv.h> is absent from this sysroot (older NetBSD/OpenBSD); no hardware
// crypto features will be detected.  Safe: BoringSSL falls back to software.
void OPENSSL_cpuid_setup(void) {}
#endif  // __has_include(<sys/auxv.h>)
#endif  // NetBSD/OpenBSD ARM 32-bit cpuid
"""
    content += stub
    with open(path, 'w') as f:
        f.write(content)
    print('cpu_arm_freebsd.cc BSD cpuid appended')
PYEOF

log "Source fixups applied"
