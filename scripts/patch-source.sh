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
log "Applying source fixups${TARGET:+ for $TARGET}"

sed -i '/};/ a\
#ifndef TEMP_FAILURE_RETRY\
#define TEMP_FAILURE_RETRY(expression) (({ long int __result; do __result = (long int)(expression); while (__result == -1 && errno == EINTR); __result; }))\
#endif\
#ifndef PAGE_SIZE\
#define PAGE_SIZE 4096\
#endif' ${PWD_SRC}/src/logging/liblog/logger.h
sed -i '/__END_DECLS/i\
#ifndef TEMP_FAILURE_RETRY\n\
#define TEMP_FAILURE_RETRY(expression) (({ long int __result; do __result = (long int)(expression); while (__result == -1 && errno == EINTR); __result; }))\n\
#endif\n' ${PWD_SRC}/src/core/libcutils/include/cutils/klog.h
sed -i '/extern "C" {/a\
#ifndef TEMP_FAILURE_RETRY\n#define TEMP_FAILURE_RETRY(expression) (({ long int __result; do __result = (long int)(expression); while (__result == -1 && errno == EINTR); __result; }))\n#endif
' ${PWD_SRC}/src/core/libcutils/uevent.cpp
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

sed -i '/#define LOG_TAG "cutils-trace"/a\
#ifndef PROP_NAME_MAX\
#define PROP_NAME_MAX 32\
#endif
' ${PWD_SRC}/src/core/libcutils/trace-dev.inc

# fml
case "$TARGET" in
  riscv32-*|powerpc-*musl*)
    sed -i 's/^\([[:space:]]*\)static_assert(std::atomic<.*>::is_always_lock_free);/\1\/\/ &/' ${PWD_SRC}/src/art/libartbase/base/metrics/metrics.h
    ;;
esac

# fml 2
sed -i '/# Set definitions and sources for ARM./i\
if(TARGET_ARCH MATCHES "^(thumb|thumbeb)$")\
    add_definitions(-DPNG_ARM_NEON_OPT=0)\
    add_definitions(-DPNG_ARM_NEON_IMPLEMENTATION=0)\
endif()
' ${PWD_SRC}/src/libpng/CMakeLists.txt
sed -i '/^namespace art {/i\
\// see aosp/art/build/art.go\
\// We need larger stack overflow guards for ASAN, as the compiled code will hav\
\// larger frame sizes. For simplicity, just use global not-target-specific cflags.\
\// Note: We increase this for both debug and non-debug, as the overflow gap will\
\//       be compiled into managed code. We always preopt (and build core images) with\
\//       the debug version. So make the gap consistent (and adjust for the worst).\
\
/*\
if len(ctx.Config().SanitizeDevice()) > 0 || len(ctx.Config().SanitizeHost()) > 0 {\
    cflags = append(cflags,\
        "-DART_STACK_OVERFLOW_GAP_arm=8192",\
        "-DART_STACK_OVERFLOW_GAP_arm64=16384",\
        "-DART_STACK_OVERFLOW_GAP_riscv64=16384",\
        "-DART_STACK_OVERFLOW_GAP_x86=16384",\
        "-DART_STACK_OVERFLOW_GAP_x86_64=20480")\
} else {\
    cflags = append(cflags,\
        "-DART_STACK_OVERFLOW_GAP_arm=8192",\
        "-DART_STACK_OVERFLOW_GAP_arm64=8192",\
        "-DART_STACK_OVERFLOW_GAP_riscv64=8192",\
        "-DART_STACK_OVERFLOW_GAP_x86=8192",\
        "-DART_STACK_OVERFLOW_GAP_x86_64=8192")\
}\
*/\
\
#define ART_STACK_OVERFLOW_GAP_arm 16384\
#define ART_STACK_OVERFLOW_GAP_arm64 16384\
#define ART_STACK_OVERFLOW_GAP_riscv64 16384\
#define ART_STACK_OVERFLOW_GAP_x86 16384\
#define ART_STACK_OVERFLOW_GAP_x86_64 20480\
#define ART_STACK_OVERFLOW_GAP_loongarch64 16384\
#define ART_STACK_OVERFLOW_GAP_powerpc 16384\
#define ART_STACK_OVERFLOW_GAP_s390x 16384\
\
\// see aosp/art/build/art.go\
\// default frame size limit: 1736\
\// device limit: 7400\
\// host limit: 10000\
#define ART_FRAME_SIZE_LIMIT 10000' ${PWD_SRC}/src/art/libartbase/arch/instruction_set.h

sed -i '/#include "os.h"/a #include <sys/cachectl.h>' ${PWD_SRC}/src/art/libartbase/base/utils.cc
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
  /^[[:space:]]*__builtin___clear_cache[[:space:]]*(/i #if !defined(__s390x__) && !defined(__ppc__)
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
# remove it first. musl builds omit -D_GNU_SOURCE and keep the #else.
sed -i '/\/\* Undefine _GNU_SOURCE/,/#undef _GNU_SOURCE/d' ${PWD_SRC}/src/libbase/posix_strerror_r.cpp
sed -i '/return strerror_r(errnum, buf, buflen);/c\
#if defined(__GLIBC__) \&\& defined(_GNU_SOURCE)\
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

# brotli: restore static-library support
( cd ${PWD_SRC}/src/brotli && git apply ../../patches/0001-add-static-support-back-to-brotli.patch )

log "Source fixups applied"
