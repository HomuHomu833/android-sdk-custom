/* <sys/vfs.h> shim for the macOS/Windows libselinux host build.
 *
 * <sys/vfs.h> (struct statfs / fstatfs) is a Linux/glibc header. selinux's
 * init.c includes it to fstatfs() an fd and compare f_type against SELINUX_MAGIC
 * when probing for a mounted selinuxfs -- something that never exists on a host
 * build. macOS provides the same struct/calls via <sys/mount.h>; mingw has no
 * statfs at all, so stub it.
 */
#ifndef ANDROID_SDK_HOST_COMPAT_SYS_VFS_H
#define ANDROID_SDK_HOST_COMPAT_SYS_VFS_H

#if defined(__APPLE__)

#include <sys/param.h>
#include <sys/mount.h>   /* struct statfs, statfs(), fstatfs() */

#else /* mingw */

#include <errno.h>
#include <sys/types.h>

struct statfs {
  long f_type;
  long f_bsize;
  long f_blocks;
  long f_bfree;
  long f_bavail;
  long f_files;
  long f_ffree;
  long f_namelen;
};

static inline __attribute__((__unused__))
int statfs(const char *__path, struct statfs *__buf) {
  (void)__path; (void)__buf;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
int fstatfs(int __fd, struct statfs *__buf) {
  (void)__fd; (void)__buf;
  errno = ENOSYS;
  return -1;
}

#endif

#endif /* ANDROID_SDK_HOST_COMPAT_SYS_VFS_H */
