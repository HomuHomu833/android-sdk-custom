/* strlcpy/strlcat compatibility shim.
 *
 * glibc only declares strlcpy()/strlcat() from 2.38; AOSP host code (e.g.
 * liblog's logd_reader.cpp) uses them unconditionally because bionic and musl
 * always provide them. Rather than bumping the targeted glibc version (which
 * would raise the runtime glibc requirement of the produced binaries), this
 * header is force-included (-include) on the gnu builds and supplies the BSD
 * functions only when the C library doesn't already declare them.
 *
 * Gated on __GLIBC__ + version, so on glibc >= 2.38 (and on musl/bionic, where
 * this header is not force-included anyway) it expands to nothing and the
 * libc's own strlcpy/strlcat are used.
 */
#ifndef ANDROID_SDK_STRL_COMPAT_H
#define ANDROID_SDK_STRL_COMPAT_H

/* This header is force-included (-include) before the translation unit's own
 * includes, so __GLIBC__/__GLIBC_PREREQ aren't defined yet -- they come from
 * <features.h>, which <string.h> pulls in. Include it first (it also declares
 * strlcpy/strlcat on glibc >= 2.38), then decide whether the shim is needed. */
#include <string.h>

#if defined(__GLIBC__) && (!defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 38))

#include <stddef.h>

/* Don't duplicate definitions when compiling the implementation file
 * (strlcpy.c) itself; it defines strlcpy as a real (extern) function. */
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
#endif /* ANDROID_SDK_STRL_COMPAT_H */
