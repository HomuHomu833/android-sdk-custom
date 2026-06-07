#!/usr/bin/env bash
# In-place source fixups for the AOSP host-tool build — the verbatim sed wall
# that used to live in the "Apply Patches" step of .github/workflows/build.yml,
# lifted out of YAML into a real script.
#
#   ROOTDIR   checkout root (default: cwd)
#   TARGET    target triple; only the per-arch conditionals below look at it
#
# Idempotency note: these are raw in-place edits (same as the old workflow), so
# run them exactly once on a fresh checkout — re-running may double-apply.
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
TARGET="${TARGET:-}"
PWD_SRC="$ROOTDIR"   # the old workflow anchored every path on ${PWD}
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- drop in the prebuilt patch files (get_source.py:patches()) -------------
log "Installing patch files"
mkdir -p src/incremental_delivery/sysprop/include
cp patches/misc/IncrementalProperties.sysprop.h   src/incremental_delivery/sysprop/include/
cp patches/misc/IncrementalProperties.sysprop.cpp src/incremental_delivery/sysprop/

cp patches/misc/deployagent.inc        src/adb/fastdeploy/deployagent/
cp patches/misc/deployagentscript.inc  src/adb/fastdeploy/deployagent/

cp patches/misc/platform_tools_version.h src/soong/cc/libbuildversion/include/

cp patches/misc/instruction_set.h        src/art/libartbase/arch/instruction_set.h
cp patches/misc/instruction_set.cc       src/art/libartbase/arch/instruction_set.cc
cp patches/misc/mem_map.h                src/art/libartbase/base/mem_map.h

cp patches/misc/target.h            src/boringssl/src/include/openssl/target.h
# getrandom_fillin.h moved between boringssl releases (crypto/fipsmodule/rand ->
# crypto/rand), so overwrite it wherever it currently lives.
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

sed -i '/};/ a\
#ifndef TEMP_FAILURE_RETRY\
#define TEMP_FAILURE_RETRY(expression) (({ long int __result; do __result = (long int)(expression); while (__result == -1 && errno == EINTR); __result; }))\
#endif\
#ifndef PAGE_SIZE\
#define PAGE_SIZE 4096\
#endif' ${PWD_SRC}/src/logging/liblog/logger.h
# NB: klog.h (klog.cpp) and uevent.cpp are now compiled only for the android
# target (libcutils.cmake target.android); bionic's <unistd.h> already provides
# TEMP_FAILURE_RETRY, so the old host-only TEMP_FAILURE_RETRY shims for them were
# dropped. logger.h's shim above stays — it's compiled on the musl host.
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
#endif' {} +

sed -i 's/__BEGIN_DECLS/#ifdef __cplusplus\nextern "C" {\n#endif/g; s/__END_DECLS/#ifdef __cplusplus\n}\n#endif/g' ${PWD_SRC}/src/core/libpackagelistparser/include/packagelistparser/packagelistparser.h

sed -i '/#include <sys\/limits.h>/d; /#include <log\/log.h>/a\
#ifndef GID_MAX\n#define GID_MAX 2147483647\n#endif\n\
#ifndef UID_MAX\n#define UID_MAX 2147483647\n#endif' ${PWD_SRC}/src/core/libpackagelistparser/packagelistparser.cpp

sed -i 's/std::vector<const StringPiece>/std::vector<StringPiece>/g' ${PWD_SRC}/src/base/tools/aapt2/util/Files.cpp

# (trace-dev.inc's PROP_NAME_MAX shim was dropped: trace-dev.cpp is android-only
# now (libcutils.cmake target.android), and bionic defines PROP_NAME_MAX.)

# fmtlib's allocator calls bare malloc()/free(), relying on <cstdlib> leaking the
# C names into the global namespace. zig 0.17's newer libc++ no longer does that,
# so pull in <stdlib.h> (which declares them globally) right after the guard.
sed -i '/#define FMT_FORMAT_H_/a #include <stdlib.h>' ${PWD_SRC}/src/fmtlib/include/fmt/format.h

# fml
case "$TARGET" in
  riscv32-*|powerpc-*)
    sed -i 's/^\([[:space:]]*\)static_assert(std::atomic<.*>::is_always_lock_free);/\1\/\/ &/' ${PWD_SRC}/src/art/libartbase/base/metrics/metrics.h
    ;;
esac

# cacheflush() (and thus <sys/cachectl.h>) is only used in utils.cc's __arm__
# branch; every other arch uses __builtin___clear_cache(). zig's generic-glibc
# <sys/cachectl.h> #include <asm/cachectl.h>, which zig doesn't ship for any of
# our targets (arm included), so on glibc forward-declare cacheflush instead;
# musl's header is self-contained, so keep including it there.
sed -i '/#include "os.h"/a\
#if defined(__arm__)\
#if defined(__GLIBC__)\
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
  int r = cacheflush(addr, size, kCacheFlushFlags);\
#else\
  int r = cacheflush(start, limit, kCacheFlushFlags);\
#endif/
}' ${PWD_SRC}/src/art/libartbase/base/utils.cc
sed -i '/FlushCpuCaches/,/}/ {
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/i #if !defined(__s390x__) && !defined(__ppc__) && !defined(__hexagon__)
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/a #endif
}' ${PWD_SRC}/src/art/libartbase/base/utils.cc

sed -i '/#if __has_feature(cxx_exceptions)/,/^#endif/ c\using Task = std::packaged_task<void()>;' ${PWD_SRC}/src/openscreen/platform/api/task_runner.h

# fml 3
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

# libbase posix_strerror_r.cpp expects the XSI strerror_r (returns int), but on
# gnu builds (-include strl_compat.h pulls in <string.h> with _GNU_SOURCE
# defined, locking in the GNU char* variant). The original file's #undef
# _GNU_SOURCE would then defeat the __GLIBC__+_GNU_SOURCE guard below, so
# remove it first. musl builds omit -D_GNU_SOURCE and keep the #else. bionic also
# ships the GNU char* variant under _GNU_SOURCE (implied by -std=gnu++20, API>=23),
# so it joins the char* branch too.
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

# abseil's 32-bit PowerPC stacktrace reads registers through glibc's mcontext
# layout (uc_mcontext.uc_regs->gregs[], where uc_regs is a pt_regs*). musl's
# ppc32 mcontext_t exposes the registers directly as uc_mcontext.gregs[], with no
# uc_regs indirection. Only rewrite for musl ppc32 — glibc ppc32 needs the
# original uc_regs-> form.
case "$TARGET" in
  powerpc-*musl*)
    for f in src/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc \
             src/abseil-cpp/absl/debugging/internal/examine_stack.cc; do
      [ -f "$f" ] && sed -i 's/uc_mcontext\.uc_regs->gregs/uc_mcontext.gregs/g' "$f"
    done
    ;;
esac

# abseil direct_mmap.h assumes "no __NR_mmap2 implies a 64-bit platform" and
# static_asserts it, which is wrong for the generic-syscall 32-bit arches
# (riscv32, hexagon): unsigned long is 4 bytes there. Replace just the assert
# with a libc mmap() fallback on non-LP64 (the original 64-bit syscall path,
# which follows, is left intact for LP64). Done as a one-line swap so it doesn't
# depend on the exact form of the syscall line after it.
sed -i 's@^\([[:space:]]*\)static_assert(sizeof(unsigned long) == 8, "Platform is not 64-bit");@#if !defined(__LP64__)\n\1return mmap(start, length, prot, flags, fd, offset);\n#endif@' \
  "${PWD_SRC}/src/abseil-cpp/absl/base/internal/direct_mmap.h"

# abseil examine_stack.cc: add hexagon support to GetProgramCounter().
# hexagon musl defines mcontext_t as struct sigcontext with a .pc field.
# Replace the `#else` / `#error` pair with the hexagon case followed by the
# original fallthrough so the file compiles on hexagon targets.
sed -i '/^#else$/{N;s/^#else\n#error "Undefined Architecture."/#elif defined(__hexagon__)\n    return reinterpret_cast<void*>(context->uc_mcontext.pc);\n#else\n#error "Undefined Architecture."/;}' \
  "${PWD_SRC}/src/abseil-cpp/absl/debugging/internal/examine_stack.cc"

# abseil conditions.h: _exit() needs <unistd.h> on hexagon musl.
# The Win32 guard incorrectly excluded hexagon, leaving _exit undeclared.
# abort() is already covered by the unconditional #include <stdlib.h> that follows.
sed -i 's/^#if defined(_WIN32) || defined(__hexagon__)$/#if defined(_WIN32)/' \
  "${PWD_SRC}/src/abseil-cpp/absl/log/internal/conditions.h"

# logging/liblog logger_name.cpp: hexagon Clang picks unsigned char as the
# underlying type for android_LogPriority (values 0-8), but the original
# static_assert demands uint32_t.  Guard both asserts (log_id_t might also
# differ) under !__hexagon__ since they're only ABI-relevant on-device.
sed -i '/^static_assert(std::is_same<std::underlying_type<log_id_t>::type, uint32_t>::value,$/i #ifndef __hexagon__' ${PWD_SRC}/src/logging/liblog/logger_name.cpp
sed -i '/^static_assert(std::is_same<std::underlying_type<android_LogPriority>::type, uint32_t>::value,$/i #ifndef __hexagon__' ${PWD_SRC}/src/logging/liblog/logger_name.cpp
sed -i '/^              "log_id_t must be an uint32_t");$/a #endif' ${PWD_SRC}/src/logging/liblog/logger_name.cpp

# selinux libsepol cil_verify.c: struct field is uint32_t* but local is
# enum cil_flavor — Clang (unlike GCC) rejects the implicit conversion in C.
sed -i 's/extra_args\.flavor = \&flavor;/extra_args.flavor = (uint32_t *)\&flavor;/' \
  ${PWD_SRC}/src/selinux/libsepol/cil/src/cil_verify.c

# brotli: restore static-library support
( cd ${PWD_SRC}/src/brotli && git apply ../../patches/0001-add-static-support-back-to-brotli.patch )

log "Source fixups applied"
