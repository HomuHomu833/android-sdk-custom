/* bionic host-tool build compatibility shim (force-included via build.sh).
 *
 * reallocarray() was only added to bionic at API level 29, but this SDK targets
 * a lower API by default (ANDROID_PLATFORM=25). AOSP's libselinux is compiled
 * with -DHAVE_REALLOCARRAY (see lib/libselinux.cmake target.android cflags),
 * which makes selinux_internal.h yield to the libc declaration -- so on API < 29
 * the call in matchpathcon.c (and friends) is left undeclared and the build
 * fails with "call to undeclared function 'reallocarray'".
 *
 * Supply a static-inline fallback for the low API levels. On API >= 29 bionic's
 * <stdlib.h> declares the real reallocarray(), so this expands to nothing and
 * the libc implementation is used instead.
 *
 * NB: guard on __ANDROID__ (a compiler predefine), not __BIONIC__ (which comes
 * from bionic's <sys/cdefs.h>) -- this header is force-included before any
 * system header, so __BIONIC__ isn't defined yet at this point. __ANDROID_API__
 * is likewise a compiler predefine and is available here.
 */
#ifndef ANDROID_SDK_BIONIC_COMPAT_H
#define ANDROID_SDK_BIONIC_COMPAT_H

#if defined(__ANDROID__) && (!defined(__ANDROID_API__) || __ANDROID_API__ < 29)

#include <errno.h>
#include <stdlib.h>

static inline __attribute__((__unused__))
void *reallocarray(void *ptr, size_t nmemb, size_t size) {
  size_t bytes;
  if (__builtin_mul_overflow(nmemb, size, &bytes)) {
    errno = ENOMEM;
    return NULL;
  }
  return realloc(ptr, bytes);
}

#endif /* __ANDROID__ && API < 29 */
#endif /* ANDROID_SDK_BIONIC_COMPAT_H */
