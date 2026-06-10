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

#include <stdint.h>

/*
 * --- Windows API compat -----------------------------------------------------
 * rand_s() is declared in <stdlib.h> on MSVC but may be hidden in MinGW
 * headers (guarded by _WIN32_WINNT >= 0x0600).  Forward-declare it here;
 * the symbol lives in msvcrt.dll on all Windows versions >= XP.
 */
#if defined(_WIN32) && !defined(rand_s)
int rand_s(unsigned int *_Value);
#endif

/*
 * --- Windows POSIX types ----------------------------------------------------
 * MinGW's <sys/types.h> omits uid_t and gid_t (they are POSIX concepts that
 * Windows does not natively express).  Provide them so that AOSP host code
 * (libpackagelistparser, libprocessgroup, etc.) compiles.
 */
#if defined(_WIN32)
#ifndef uid_t_defined
typedef unsigned int uid_t;
#define uid_t_defined
#endif
#ifndef gid_t_defined
typedef unsigned int gid_t;
#define gid_t_defined
#endif
#endif

/*
 * --- macOS BSD extensions --------------------------------------------------------
 * macOS Clang with -std=gnu* does NOT implicitly define _DARWIN_C_SOURCE
 * (unlike Linux where -std=gnu* defines _GNU_SOURCE).  Several AOSP sources
 * or transitively-included library headers define _XOPEN_SOURCE=700, which
 * hides BSD extensions (flock, LOCK_EX, getprogname, etc.).  Restore them
 * unconditionally so the host-tool build sees a consistent POSIX+BSD API.
 */
#if defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
/* RFC 3542 IPv6 socket options (IPV6_PKTINFO, IPV6_RECVPKTINFO, etc.) are
 * hidden behind this macro in <netinet/in.h> on macOS.  AOSP/Chromium code
 * that uses packet-info control messages for IPv6 requires it.
 */
#ifndef __APPLE_USE_RFC_3542
#define __APPLE_USE_RFC_3542 1
#endif
#endif

/*
 * --- macOS extended attributes --------------------------------------------------
 * f2fs-tools sources call setxattr/lsetxattr/fsetxattr under an
 * #elif defined(__APPLE__) branch with the macOS 6-arg signature.
 * Stub them out — extended attribute operations are not needed for host
 * builds that pack images.
 */
#if defined(__APPLE__)
#ifndef XATTR_CREATE
#define XATTR_CREATE 0x0002
#endif
#include <sys/types.h>
static inline __attribute__((__unused__))
int setxattr(const char *path, const char *name, const void *value,
             size_t size, uint32_t position, int options) {
  (void)path; (void)name; (void)value; (void)size; (void)position; (void)options;
  return 0;
}
static inline __attribute__((__unused__))
int lsetxattr(const char *path, const char *name, const void *value,
              size_t size, uint32_t position, int options) {
  (void)path; (void)name; (void)value; (void)size; (void)position; (void)options;
  return 0;
}
static inline __attribute__((__unused__))
int fsetxattr(int fd, const char *name, const void *value,
              size_t size, uint32_t position, int options) {
  (void)fd; (void)name; (void)value; (void)size; (void)position; (void)options;
  return 0;
}
#endif

/*
 * --- macOS getprogname() ------------------------------------------------------
 * AOSP code sometimes uses getprogname() (a BSD extension), but it is hidden on
 * macOS when _XOPEN_SOURCE=700 is in effect (POSIX conformance mode strips BSD
 * symbols).  Provide it ourselves so that the library compiles regardless of the
 * XOPEN_SOURCE level.
 */
#if defined(__APPLE__)
#include <crt_externs.h>

static inline __attribute__((__unused__))
const char *getprogname(void) {
  return (*_NSGetArgv())[0];
}
#endif

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

/*
 * --- macOS POSIX scheduling ---------------------------------------------------
 * macOS lacks the Linux-specific SCHED_BATCH and SCHED_IDLE policies, and
 * does not provide sched_setscheduler() at all.  Stub them so that
 * libprocessgroup (task_profiles.cpp) compiles for host builds (the
 * scheduling calls are inert on macOS anyway).
 */
#if defined(__APPLE__)
#include <sched.h>

#ifndef SCHED_BATCH
#define SCHED_BATCH 3
#endif
#ifndef SCHED_IDLE
#define SCHED_IDLE 5
#endif

static inline __attribute__((__unused__))
int sched_setscheduler(int pid, int policy, const struct sched_param *param) {
  (void)pid; (void)policy; (void)param;
  return 0;
}
#endif

/*
 * --- Windows stat() macros ----------------------------------------------------
 * MinGW's <sys/stat.h> omits S_ISLNK and S_ISSOCK (Windows has no symlinks
 * or sockets-as-file-types in the traditional sense).  Provide them so that
 * libselinux code such as stringrep.c and label_file.h compiles.
 */
#if defined(_WIN32)
/* S_IFLNK / S_IFSOCK are missing from MinGW's <sys/stat.h> */
#ifndef S_IFLNK
#define S_IFLNK 0xA000
#endif
#ifndef S_IFSOCK
#define S_IFSOCK 0xC000
#endif
#ifndef S_ISLNK
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)
#endif
#ifndef S_ISSOCK
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)
#endif
/* MinGW's <sys/stat.h> declares stat() but not lstat() — Windows has no
 * symlinks, so a path stat never differs from a link stat.  Map lstat onto
 * stat so e2fsprogs (lib/blkid/devno.c) and other host code that probes the
 * filesystem compiles.  Using a macro inherits MinGW's _FILE_OFFSET_BITS=64
 * remapping of stat -> _stat64 (and struct stat -> struct _stat64), which an
 * inline wrapper would not. */
#ifndef lstat
#define lstat stat
#endif
#endif

/*
 * --- getline() ----------------------------------------------------------------
 * MinGW does not provide POSIX getline().  Provide a simple fallback so that
 * libselinux (label_file.c, selinux_config.c) and other host code can use it.
 */
#if defined(_WIN32) && !defined(HAVE_GETLINE)
#include <stdio.h>
#include <stdlib.h>

static inline __attribute__((__unused__))
ssize_t getline(char **lineptr, size_t *n, FILE *stream) {
  size_t pos = 0;
  int c;
  if (*lineptr == NULL || *n == 0) {
    *n = 120;
    *lineptr = (char *)malloc(*n);
    if (*lineptr == NULL) return -1;
  }
  while ((c = fgetc(stream)) != EOF) {
    if (pos + 1 >= *n) {
      *n *= 2;
      char *newp = (char *)realloc(*lineptr, *n);
      if (newp == NULL) return -1;
      *lineptr = newp;
    }
    (*lineptr)[pos++] = (char)c;
    if (c == '\n') break;
  }
  if (pos == 0) return -1;
  (*lineptr)[pos] = '\0';
  return (ssize_t)pos;
}
#define HAVE_GETLINE 1
#endif

/*
 * --- reallocarray() ----------------------------------------------------------
 * libsepol is compiled with -DHAVE_REALLOCARRAY which skips the static
 * declaration in selinux_internal.h, but macOS  and MinGW may still lack a
 * libc declaration.  Provide a static-inline fallback for those platforms;
 * on bionic it is guarded by the API level (added at API 29).
 */
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
#endif

/* --- bionic / Android NDK specific fallbacks ------------------------------- */
#if defined(__ANDROID__)

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

/*
 * --- Windows POSIX types ----------------------------------------------------
 * MinGW's <sys/types.h> omits uid_t and gid_t (they are POSIX concepts that
 * Windows does not natively express).  Provide them so that AOSP host code
 * (libpackagelistparser, libprocessgroup, etc.) compiles.
 */
#if defined(_WIN32)
#ifndef uid_t_defined
typedef unsigned int uid_t;
#define uid_t_defined
#endif
#ifndef gid_t_defined
typedef unsigned int gid_t;
#define gid_t_defined
#endif
#endif

/*
 * --- Windows POSIX identity stubs --------------------------------------------
 * e2fsprogs lib/blkid/cache.c calls getuid/geteuid/getgid/getegid in its
 * safe_getenv() helper.  These POSIX concepts don't exist on Windows; return 0
 * (interpreted as "not running setuid/setgid") so the check is a no-op.
 */
#if defined(_WIN32)
static inline uid_t getuid(void) { return 0; }
static inline uid_t geteuid(void) { return 0; }
static inline gid_t getgid(void) { return 0; }
static inline gid_t getegid(void) { return 0; }
#endif

/*
 * --- Windows sys/sysmacros.h (makedev/major/minor) ---------------------------
 * llvm-mingw ships no <sys/sysmacros.h>, and its <sys/types.h> does not define
 * the device-number macros.  e2fsprogs lib/blkid/devname.c uses makedev() in
 * its Linux-only /sys and EVMS scan paths (dead code on Windows, but still
 * compiled).  config.h's HAVE_SYS_SYSMACROS_H is suppressed for _WIN32 (see
 * scripts/patch-source.sh) so the missing header is never #include'd; provide
 * the macros here instead, matching e2fsprogs' own include/mingw/sys/sysmacros.h.
 */
#if defined(_WIN32)
#ifndef makedev
#define makedev(maj, min) (((maj) << 8) + (min))
#endif
#ifndef major
#define major(dev) ((int)(((dev) >> 8) & 0xff))
#endif
#ifndef minor
#define minor(dev) ((int)((dev) & 0xff))
#endif
#endif

/*
 * --- Windows malloc_usable_size ----------------------------------------------
 * sqlite3 is built with -DHAVE_MALLOC_USABLE_SIZE on every platform, but the
 * Windows CRT has no malloc_usable_size: the ucrt equivalent is _msize().
 * Forward-declaring malloc_usable_size (as we used to) lets the code compile but
 * leaves an undefined symbol at link time, so define it as an inline wrapper
 * over _msize() instead.  _msize(NULL) is undefined, so mirror glibc and return
 * 0 for a NULL pointer.
 */
#if defined(_WIN32) && !defined(malloc_usable_size)
#include <malloc.h>
static inline __attribute__((__unused__))
size_t malloc_usable_size(void *ptr) { return ptr ? _msize(ptr) : 0; }
#endif

#endif /* HOST_COMPAT_H */
