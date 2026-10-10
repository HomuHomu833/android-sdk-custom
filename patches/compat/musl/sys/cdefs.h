/* musl ships no <sys/cdefs.h> (by design), but AOSP code written against
 * glibc and bionic includes it for the __BEGIN_DECLS/__END_DECLS brackets.
 * scripts/build.sh puts this directory on the include path of musl builds only;
 * every other libc has its own. */
#ifndef SDK_COMPAT_SYS_CDEFS_H
#define SDK_COMPAT_SYS_CDEFS_H

#ifdef __cplusplus
#define __BEGIN_DECLS extern "C" {
#define __END_DECLS }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif

/* bionic's API-level annotation; meaningless off Android. */
#ifndef __INTRODUCED_IN
#define __INTRODUCED_IN(api_level)
#endif

#endif /* SDK_COMPAT_SYS_CDEFS_H */
