/* strlcpy/strlcat compatibility shim.
 *
 * glibc declares strlcpy/strlcat only from 2.38, but AOSP host code (e.g. liblog's
 * logd_reader.cpp) uses them unconditionally (bionic/musl always provide them).
 * Rather than raise the binaries' runtime glibc floor, force-include this on gnu
 * builds to supply the BSD functions when the libc doesn't. Gated on __GLIBC__ +
 * version, so on glibc >= 2.38 (and musl/bionic, where it isn't included) it's a
 * no-op. */
#ifndef ANDROID_SDK_STRL_COMPAT_H
#define ANDROID_SDK_STRL_COMPAT_H

/* Force-included before the TU's own includes, so __GLIBC__/__GLIBC_PREREQ aren't
 * set yet — they come from <features.h> via <string.h>. Include it first (it also
 * declares strlcpy/strlcat on glibc >= 2.38), then decide if the shim is needed. */
#include <string.h>

#if defined(__GLIBC__) && (!defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 38))

#include <stddef.h>

/* Skip when compiling the implementation file (strlcpy.c), which defines strlcpy
 * as a real extern function. */
#ifndef ANDROID_SDK_STRL_COMPAT_IMPLEMENTATION

static inline __attribute__((__unused__))
size_t strlcpy(char *dst, const char *src, size_t dsize) {
  const char *osrc = src;
  size_t nleft = dsize;
  if (nleft != 0) {
    while (--nleft != 0) {
      if ((*dst++ = *src++) == '\0') break;
    }
  }
  if (nleft == 0) {
    if (dsize != 0) *dst = '\0';
    while (*src++) {
    }
  }
  return (size_t)(src - osrc - 1);
}

static inline __attribute__((__unused__))
size_t strlcat(char *dst, const char *src, size_t dsize) {
  const char *odst = dst;
  const char *osrc = src;
  size_t n = dsize;
  size_t dlen;
  while (n-- != 0 && *dst != '\0') dst++;
  dlen = (size_t)(dst - odst);
  n = dsize - dlen;
  if (n-- == 0) return dlen + strlen(src);
  while (*src != '\0') {
    if (n != 0) {
      *dst++ = *src;
      n--;
    }
    src++;
  }
  *dst = '\0';
  return dlen + (size_t)(src - osrc);
}

#endif /* !ANDROID_SDK_STRL_COMPAT_IMPLEMENTATION */
#endif /* glibc < 2.38 */

/* qsort_r: added to glibc in 2.8. zig's MIPS glibc sysroot minimum is older,
 * so the declaration may be absent even with _GNU_SOURCE=1. Supply a
 * thread-unsafe shim (single-threaded callers like zstd dictBuilder are fine).
 * Static per-TU so it doesn't conflict with any real symbol at link time. */
#if defined(__GLIBC__) && (!defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 8))
#include <stdlib.h>
static void *_qsort_r_ctx_;
static int (*_qsort_r_fn_)(const void *, const void *, void *);
static int _qsort_r_wrap_(const void *a, const void *b) {
    return _qsort_r_fn_(a, b, _qsort_r_ctx_);
}
static __attribute__((__unused__)) void
qsort_r(void *base, size_t nmemb, size_t size,
        int (*cmp)(const void *, const void *, void *), void *arg) {
    _qsort_r_ctx_ = arg; _qsort_r_fn_ = cmp;
    qsort(base, nmemb, size, _qsort_r_wrap_);
}
#endif /* glibc < 2.8 */

#endif /* ANDROID_SDK_STRL_COMPAT_H */
