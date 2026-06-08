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

#if defined(__ANDROID__)

/* bionic lacks the glibc/musl GNU stdio "*_unlocked" extensions at the API
 * levels we target (it only ships the POSIX getc/putc/getchar/putchar variants),
 * but AOSP host code such as selinux's selinux_config.c / label_file.c uses them
 * as a single-threaded perf optimization. The _unlocked forms differ from the
 * plain ones only in skipping the per-FILE lock, so mapping them to the locked
 * equivalents is functionally identical here. */
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

/* reallocarray() was only added to bionic at API level 29; supply a fallback for
 * the lower API levels. On API >= 29 bionic's <stdlib.h> declares the real one,
 * so this expands to nothing and the libc implementation is used instead. */
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

/* __system_property_read_callback() was added in API 26; provide it for the
 * lower API levels in terms of the long-available __system_property_read() so
 * host-tool code that reads build properties (soong's libbuildversion.cpp)
 * compiles. On API >= 26 bionic declares the real one and this is skipped. */
#if !defined(__ANDROID_API__) || __ANDROID_API__ < 26
#include <stdint.h>
#include <sys/system_properties.h>

static inline __attribute__((__unused__))
void __system_property_read_callback(
    const prop_info *__pi,
    void (*__callback)(void *__cookie, const char *__name,
                       const char *__value, uint32_t __serial),
    void *__cookie) {
  char __name[PROP_NAME_MAX];
  char __value[PROP_VALUE_MAX];
  int __len = __system_property_read(__pi, __name, __value);
  if (__len >= 0)
    __callback(__cookie, __name, __value, 0);
}
#endif /* API < 26 */

#endif /* __ANDROID__ */
#endif /* ANDROID_SDK_BIONIC_COMPAT_H */
