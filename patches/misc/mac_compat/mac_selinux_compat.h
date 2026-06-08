/* Force-included for the macOS (osxcross) libselinux host build.
 *
 * selinux's *filecon sources use the Linux extended-attribute API and the
 * Linux O_PATH flag. macOS's <sys/xattr.h> has the same calls but with two
 * extra arguments (position, options) and no l*xattr / O_PATH. These code paths
 * (setting/getting a file's security context) never run on a host build, so map
 * the Linux 5-arg forms onto the macOS 6-arg ones (and the l*xattr variants
 * onto XATTR_NOFOLLOW) so the translation units compile.
 *
 * The wrappers are defined before the macros so their own calls bind to the
 * real libc functions; the macros then rewrite selinux's Linux-style calls.
 */
#ifndef ANDROID_SDK_MAC_SELINUX_COMPAT_H
#define ANDROID_SDK_MAC_SELINUX_COMPAT_H

#include <fcntl.h>
#include <sys/types.h>
#include <sys/xattr.h>

/* O_PATH has no macOS equivalent; selinux only uses it to test an fd's flags,
 * which is a no-op on a host build. */
#ifndef O_PATH
#define O_PATH 0
#endif

static inline __attribute__((__unused__))
int __sel_setxattr(const char *__path, const char *__name,
                   const void *__value, size_t __size, int __flags) {
  return setxattr(__path, __name, __value, __size, 0, __flags);
}
static inline __attribute__((__unused__))
int __sel_lsetxattr(const char *__path, const char *__name,
                    const void *__value, size_t __size, int __flags) {
  return setxattr(__path, __name, __value, __size, 0, __flags | XATTR_NOFOLLOW);
}
static inline __attribute__((__unused__))
int __sel_fsetxattr(int __fd, const char *__name, const void *__value,
                    size_t __size, int __flags) {
  return fsetxattr(__fd, __name, __value, __size, 0, __flags);
}
static inline __attribute__((__unused__))
ssize_t __sel_getxattr(const char *__path, const char *__name,
                       void *__value, size_t __size) {
  return getxattr(__path, __name, __value, __size, 0, 0);
}
static inline __attribute__((__unused__))
ssize_t __sel_lgetxattr(const char *__path, const char *__name,
                        void *__value, size_t __size) {
  return getxattr(__path, __name, __value, __size, 0, XATTR_NOFOLLOW);
}
static inline __attribute__((__unused__))
ssize_t __sel_fgetxattr(int __fd, const char *__name,
                        void *__value, size_t __size) {
  return fgetxattr(__fd, __name, __value, __size, 0, 0);
}

#define setxattr(p, n, v, s, f)   __sel_setxattr((p), (n), (v), (s), (f))
#define lsetxattr(p, n, v, s, f)  __sel_lsetxattr((p), (n), (v), (s), (f))
#define fsetxattr(fd, n, v, s, f) __sel_fsetxattr((fd), (n), (v), (s), (f))
#define getxattr(p, n, v, s)      __sel_getxattr((p), (n), (v), (s))
#define lgetxattr(p, n, v, s)     __sel_lgetxattr((p), (n), (v), (s))
#define fgetxattr(fd, n, v, s)    __sel_fgetxattr((fd), (n), (v), (s))

#endif /* ANDROID_SDK_MAC_SELINUX_COMPAT_H */
