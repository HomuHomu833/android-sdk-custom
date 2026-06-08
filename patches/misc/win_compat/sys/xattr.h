/* Stub <sys/xattr.h> for the Windows (mingw) libselinux host build.
 *
 * mingw has no extended-attribute API at all, but selinux's *filecon sources
 * include <sys/xattr.h> and call [f|l]{set,get}xattr to read/write a file's
 * security context. Those operations are meaningless on a Windows host and the
 * host tools never invoke them, so provide Linux-signature stubs that fail with
 * ENOTSUP. This header is found via the win_compat dir on libselinux's include
 * path (PLATFORM_WINDOWS only).
 */
#ifndef ANDROID_SDK_WIN_COMPAT_SYS_XATTR_H
#define ANDROID_SDK_WIN_COMPAT_SYS_XATTR_H

#include <errno.h>
#include <sys/types.h>

#define XATTR_CREATE  0x1
#define XATTR_REPLACE 0x2

static inline __attribute__((__unused__))
int setxattr(const char *__path, const char *__name, const void *__value,
             size_t __size, int __flags) {
  (void)__path; (void)__name; (void)__value; (void)__size; (void)__flags;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
int lsetxattr(const char *__path, const char *__name, const void *__value,
              size_t __size, int __flags) {
  (void)__path; (void)__name; (void)__value; (void)__size; (void)__flags;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
int fsetxattr(int __fd, const char *__name, const void *__value,
              size_t __size, int __flags) {
  (void)__fd; (void)__name; (void)__value; (void)__size; (void)__flags;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
ssize_t getxattr(const char *__path, const char *__name,
                 void *__value, size_t __size) {
  (void)__path; (void)__name; (void)__value; (void)__size;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
ssize_t lgetxattr(const char *__path, const char *__name,
                  void *__value, size_t __size) {
  (void)__path; (void)__name; (void)__value; (void)__size;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
ssize_t fgetxattr(int __fd, const char *__name, void *__value, size_t __size) {
  (void)__fd; (void)__name; (void)__value; (void)__size;
  errno = ENOSYS;
  return -1;
}

#endif /* ANDROID_SDK_WIN_COMPAT_SYS_XATTR_H */
