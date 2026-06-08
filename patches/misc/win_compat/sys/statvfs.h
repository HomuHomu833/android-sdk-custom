/* Stub <sys/statvfs.h> for the Windows (mingw) libselinux host build.
 *
 * mingw ships no <sys/statvfs.h>, but selinux's init.c includes it and calls
 * statvfs()/checks ST_RDONLY when verifying that a mounted selinuxfs is
 * writable -- a probe that can never succeed on a Windows host and that the
 * host tools never exercise. Provide the POSIX struct/constant/signatures so
 * the translation unit compiles; the call fails inertly with ENOSYS. Found via
 * the win_compat dir on libselinux's include path (PLATFORM_WINDOWS only).
 */
#ifndef ANDROID_SDK_WIN_COMPAT_SYS_STATVFS_H
#define ANDROID_SDK_WIN_COMPAT_SYS_STATVFS_H

#include <errno.h>
#include <sys/types.h>

#ifndef ST_RDONLY
#define ST_RDONLY 0x0001UL
#endif
#ifndef ST_NOSUID
#define ST_NOSUID 0x0002UL
#endif

struct statvfs {
  unsigned long f_bsize;
  unsigned long f_frsize;
  unsigned long f_blocks;
  unsigned long f_bfree;
  unsigned long f_bavail;
  unsigned long f_files;
  unsigned long f_ffree;
  unsigned long f_favail;
  unsigned long f_fsid;
  unsigned long f_flag;
  unsigned long f_namemax;
};

static inline __attribute__((__unused__))
int statvfs(const char *__path, struct statvfs *__buf) {
  (void)__path; (void)__buf;
  errno = ENOSYS;
  return -1;
}
static inline __attribute__((__unused__))
int fstatvfs(int __fd, struct statvfs *__buf) {
  (void)__fd; (void)__buf;
  errno = ENOSYS;
  return -1;
}

#endif /* ANDROID_SDK_WIN_COMPAT_SYS_STATVFS_H */
