/* Host-tool build compatibility shim (force-included via build.sh).
 *
 * AOSP host-tool code expects glibc/musl GNU extensions and newer POSIX/libc
 * APIs that the target libc (bionic, macOS, MinGW) may not ship at the
 * configured SDK level.  This header fills those gaps so the cross-build
 * compiles without source-level patches.
 *
 * Each section is guarded by its platform define so it only applies where
 * the real libc does not provide the symbol. */
#ifndef HOST_COMPAT_H
#define HOST_COMPAT_H

/*
 * --- stdio *_unlocked extensions -------------------------------------------
 * bionic, macOS and MinGW all lack the glibc/musl GNU stdio *_unlocked
 * functions (fgets_unlocked, etc.).  AOSP host code such as libselinux uses
 * them as a single-threaded perf optimization.  Map them to the locked
 * equivalents (functionally identical on single-threaded or host builds).
 */
#if defined(__APPLE__) || defined(_WIN32) || defined(__ANDROID__)
#ifndef fgets_unlocked
#define fgets_unlocked(s, n, f)      fgets((s), (n), (f))
#endif
#ifndef fputs_unlocked
#define fputs_unlocked(s, f)         fputs((s), (f))
#endif
#ifndef fread_unlocked
#define fread_unlocked(p, sz, n, f)  fread((p), (sz), (n), (f))
#endif
#ifndef fwrite_unlocked
#define fwrite_unlocked(p, sz, n, f) fwrite((p), (sz), (n), (f))
#endif
#ifndef fgetc_unlocked
#define fgetc_unlocked(f)            fgetc((f))
#endif
#ifndef fputc_unlocked
#define fputc_unlocked(c, f)         fputc((c), (f))
#endif
#ifndef fflush_unlocked
#define fflush_unlocked(f)           fflush((f))
#endif
#endif

/* --- bionic / Android NDK specific fallbacks ------------------------------- */
#if defined(__ANDROID__)

/* reallocarray() was only added to bionic at API level 29.  AOSP's libselinux
 * is compiled with -DHAVE_REALLOCARRAY which makes selinux_internal.h yield to
 * the libc declaration, so on API < 29 the call is left undeclared. */
#if !defined(__ANDROID_API__) || __ANDROID_API__ < 29
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
#endif /* API < 29 */

/* hasmntopt() was only added to bionic at API level 26; e2fsprogs' ismounted.c
 * uses it to test a mount entry's options. */
#if !defined(__ANDROID_API__) || __ANDROID_API__ < 26
#include <mntent.h>
#include <string.h>

static inline __attribute__((__unused__))
char *hasmntopt(const struct mntent *mnt, const char *opt) {
  const size_t optlen = strlen(opt);
  char *rest = mnt->mnt_opts, *p;
  while ((p = strstr(rest, opt)) != NULL) {
    if ((p == mnt->mnt_opts || p[-1] == ',') &&
        (p[optlen] == '\0' || p[optlen] == ',' || p[optlen] == '=')) {
      return p;
    }
    rest = strchr(p, ',');
    if (rest == NULL) break;
    ++rest;
  }
  return NULL;
}
#endif /* API < 26 */

/* getlogin_r() was only added to bionic at API level 28; adb's sysdeps.h uses
 * it for host-name lookup. */
#if !defined(__ANDROID_API__) || __ANDROID_API__ < 28
#include <unistd.h>
#include <errno.h>

static inline __attribute__((__unused__))
int getlogin_r(char *buf, size_t bufsize) {
  if (bufsize == 0) return ERANGE;
  buf[0] = '\0';
  return 0;
}
#endif /* API < 28 */

#endif /* __ANDROID__ */
#endif /* HOST_COMPAT_H */
