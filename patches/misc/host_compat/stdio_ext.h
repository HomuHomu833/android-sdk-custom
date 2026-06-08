/* Minimal <stdio_ext.h> shim for the macOS/Windows libselinux host build.
 *
 * <stdio_ext.h> is a glibc extension; the BSD libc (macOS) and mingw don't ship
 * it. selinux's init.c includes it for __fsetlocking(), a single-threaded perf
 * hint (switch a FILE to caller-managed locking). On a host build that hint is
 * irrelevant, so provide the constants and a no-op that reports caller locking.
 */
#ifndef ANDROID_SDK_HOST_COMPAT_STDIO_EXT_H
#define ANDROID_SDK_HOST_COMPAT_STDIO_EXT_H

#include <stdio.h>

#define FSETLOCKING_QUERY    0
#define FSETLOCKING_INTERNAL 1
#define FSETLOCKING_BYCALLER 2

static inline __attribute__((__unused__))
int __fsetlocking(FILE *__fp, int __type) {
  (void)__fp;
  (void)__type;
  return FSETLOCKING_INTERNAL;
}

#endif /* ANDROID_SDK_HOST_COMPAT_STDIO_EXT_H */
