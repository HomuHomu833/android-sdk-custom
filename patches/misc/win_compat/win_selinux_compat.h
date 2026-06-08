/* Force-included for the Windows (mingw) libselinux host build.
 *
 * selinux's host code uses a handful of POSIX constants/flags that mingw's
 * headers don't define. The code paths behind them are selinuxfs/kernel calls
 * that never run on a host build, so defining harmless values is enough to let
 * the translation units compile.
 */
#ifndef ANDROID_SDK_WIN_SELINUX_COMPAT_H
#define ANDROID_SDK_WIN_SELINUX_COMPAT_H

#include <fcntl.h>
#include <string.h>

/* close-on-exec has no meaning for the host-only selinuxfs open() paths */
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

/* stpcpy() is a POSIX/GNU extension mingw doesn't provide; selinux uses it
 * (e.g. context.c). Supply the standard "copy and return end pointer" form. */
#ifndef ANDROID_SDK_HAVE_STPCPY
#define ANDROID_SDK_HAVE_STPCPY
static inline __attribute__((__unused__))
char *stpcpy(char *__dst, const char *__src) {
  size_t __len = strlen(__src);
  return (char *)memcpy(__dst, __src, __len + 1) + __len;
}
#endif

#endif /* ANDROID_SDK_WIN_SELINUX_COMPAT_H */
