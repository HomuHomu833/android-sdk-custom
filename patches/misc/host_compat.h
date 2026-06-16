/* Host-tool build compatibility shim (force-included via build.sh).
 *
 * AOSP host-tool code expects glibc/musl GNU extensions and newer POSIX/libc APIs
 * the target libc (bionic, macOS, MinGW, BSD) may not ship; this header fills the
 * gaps so the cross-build compiles without source patches. Each section is guarded
 * by its platform define. */
#ifndef HOST_COMPAT_H
#define HOST_COMPAT_H

/* --- BSD feature-test macros (MUST precede all #includes) -------------------
 * The opening #include <stdint.h> pulls in <sys/cdefs.h>, which evaluates these
 * then, so set them first. NetBSD: _NETBSD_SOURCE enables the extension API
 * (locale_t, _l-functions) libcxx needs, which liblog's -D_XOPEN_SOURCE=700 would
 * otherwise suppress. FreeBSD/OpenBSD: __BSD_VISIBLE enables BSD APIs (vasprintf,
 * getprogname); OpenBSD also needs _BSD_SOURCE so cdefs.h keeps __BSD_VISIBLE. */
#if defined(__NetBSD__)
# ifndef _NETBSD_SOURCE
#  define _NETBSD_SOURCE 1
# endif
#endif

#if defined(__FreeBSD__) || defined(__OpenBSD__)
# ifndef __BSD_VISIBLE
#  define __BSD_VISIBLE 1
# endif
#endif
#if defined(__OpenBSD__)
# ifndef _BSD_SOURCE
#  define _BSD_SOURCE 1
# endif
#endif

/* --- BSD LFS64 aliases ------------------------------------------------------
 * AOSP uses glibc's LFS64 aliases (lseek64, off64_t, ...); BSDs lack them but
 * their off_t/functions are already 64-bit, so map each to the plain name.
 * FreeBSD declares off64_t itself; NetBSD/OpenBSD need it too. */
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
# ifndef lseek64
#  define lseek64      lseek
# endif
# ifndef mmap64
#  define mmap64       mmap
# endif
# ifndef pread64
#  define pread64      pread
# endif
# ifndef pwrite64
#  define pwrite64     pwrite
# endif
# ifndef ftruncate64
#  define ftruncate64  ftruncate
# endif
#endif
#if defined(__NetBSD__) || defined(__OpenBSD__)
# ifndef off64_t
#  define off64_t off_t
# endif
#endif

/* --- BSD pthread process-shared stubs ---------------------------------------
 * AOSP's Mutex/Condition/RWLock SHARED ctors call pthread_*attr_setpshared() —
 * dead code on host but must compile. NetBSD guards all three behind
 * _PTHREAD_PSHARED (never defined); OpenBSD lacks mutex/cond (rwlock is present);
 * FreeBSD declares all three. */
#if defined(__NetBSD__) && !defined(_PTHREAD_PSHARED)
# define pthread_rwlockattr_setpshared(attr, val) (0)
# define pthread_mutexattr_setpshared(attr, val)  (0)
# define pthread_condattr_setpshared(attr, val)   (0)
#endif
#if defined(__OpenBSD__)
# define pthread_mutexattr_setpshared(attr, val)  (0)
# define pthread_condattr_setpshared(attr, val)   (0)
#endif

#include <stdint.h>

/* --- BSD sys/socket.h + netinet/in.h ----------------------------------------
 * BSD zig sysroots' <netinet/in.h> doesn't pull in <sys/socket.h> (unlike glibc),
 * but AOSP (libsepol kernel_to_cil/conf.c) uses AF_INET* after only including it.
 * FreeBSD also needs netinet/in.h for `struct in6_addr` (cil_internal.h). */
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
# include <sys/socket.h>
# include <sys/time.h>
# include <netinet/in.h>
#endif

/* --- OpenBSD pthread_set_name_np --------------------------------------------
 * Declared in <pthread_np.h> on OpenBSD, not <pthread.h>; adb/sysdeps.h calls it. */
#if defined(__OpenBSD__)
#include <pthread_np.h>
#endif

/* --- NetBSD ip_mreqn --------------------------------------------------------
 * struct ip_mreqn is a Linux/FreeBSD/OpenBSD extension NetBSD lacks; openscreen's
 * udp_socket.cpp uses decltype(ip_mreqn().imr_ifindex) for the index type only. */
#if defined(__NetBSD__) && !defined(IP_MULTICAST_IFINDEX)
#include <netinet/in.h>
struct ip_mreqn {
    struct in_addr imr_multiaddr;
    struct in_addr imr_address;
    int            imr_ifindex;
};
#endif

/* --- FreeBSD/OpenBSD in_pktinfo / IP_PKTINFO --------------------------------
 * Added in FreeBSD 14.0 / OpenBSD 7.3; older zig sysroots lack them while adb's
 * openscreen udp_socket.cpp uses them unconditionally. Define them so it compiles;
 * at runtime older kernels just return ENOPROTOOPT and the code falls back. */
#if (defined(__FreeBSD__) || defined(__OpenBSD__)) && !defined(IP_PKTINFO)
#include <netinet/in.h>
struct in_pktinfo {
    struct in_addr  ipi_addr;      /* Header destination address */
    struct in_addr  ipi_spec_dst;  /* Local source address */
    unsigned int    ipi_ifindex;   /* Interface index */
};
#if defined(__FreeBSD__)
#define IP_PKTINFO 19  /* FreeBSD 14+ */
#else
#define IP_PKTINFO 26  /* OpenBSD 7.3+ */
#endif
#endif

/* --- BSD mempcpy ------------------------------------------------------------
 * GNU extension (copy n bytes, return dst+n) adb uses unconditionally; BSD libcs
 * lack it, so provide an inline fallback. */
#if defined(__OpenBSD__) && !defined(mempcpy)
#include <string.h>
static inline __attribute__((__unused__))
void *mempcpy(void *dst, const void *src, size_t n) {
    return (char *)memcpy(dst, src, n) + n;
}
#endif

/* --- BSD MAP_32BIT ----------------------------------------------------------
 * Linux mmap() flag (map below 2 GB) libartbase/mem_map.cc uses under __LP64__;
 * BSDs have no equivalent, so 0 makes it a no-op. */
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
# ifndef MAP_32BIT
#  define MAP_32BIT 0
# endif
#endif

/* --- Windows wincrypt guard -------------------------------------------------
 * <wincrypt.h> macros (e.g. X509_NAME) clash with BoringSSL typedefs; NOCRYPT
 * disables them while still allowing the header's non-crypto functions. */
#if defined(_WIN32) && !defined(NOCRYPT)
#define NOCRYPT
#endif

/* --- Windows rand_s ---------------------------------------------------------
 * Hidden in MinGW headers (gated on _WIN32_WINNT >= 0x0600); forward-declare it —
 * the symbol is in msvcrt.dll on all Windows >= XP. */
#if defined(_WIN32) && !defined(rand_s)
int rand_s(unsigned int *_Value);
#endif

/* --- Windows POSIX types ----------------------------------------------------
 * MinGW omits uid_t/gid_t; provide them for libpackagelistparser, libprocessgroup. */
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

/* --- macOS BSD extensions ---------------------------------------------------
 * macOS Clang with -std=gnu* doesn't auto-define _DARWIN_C_SOURCE, and AOSP code
 * with _XOPEN_SOURCE=700 hides BSD extensions (flock, getprogname); define it to
 * restore them. Valueless to match e2fsprogs' bare #define (cdefs.h only tests
 * defined()), avoiding -Wmacro-redefined. */
#if defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE
#endif
/* RFC 3542 IPv6 socket options (IPV6_PKTINFO, ...) are gated behind this macro in
 * <netinet/in.h> on macOS; AOSP/Chromium pktinfo code needs it. */
#ifndef __APPLE_USE_RFC_3542
#define __APPLE_USE_RFC_3542 1
#endif
#endif

/* --- macOS extended attributes ----------------------------------------------
 * f2fs-tools calls setxattr/lsetxattr/fsetxattr (macOS 6-arg form); stub them —
 * xattrs aren't needed for host image packing. */
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

/* --- macOS getprogname ------------------------------------------------------
 * BSD extension hidden under _XOPEN_SOURCE=700; provide it so the build is
 * independent of the XOPEN level. */
#if defined(__APPLE__)
#include <crt_externs.h>

static inline __attribute__((__unused__))
const char *getprogname(void) {
  return (*_NSGetArgv())[0];
}
#endif

/* --- stdio *_unlocked extensions --------------------------------------------
 * bionic/macOS/MinGW lack the glibc GNU *_unlocked stdio funcs (used by libselinux
 * as a single-threaded perf hint); map them to the locked equivalents. FreeBSD
 * ships them, so it's excluded. fgets_unlocked matches libselinux
 * label_internal.h's exact spelling (it redefines unconditionally) to stay
 * token-identical and avoid -Wmacro-redefined. */
#if (defined(__APPLE__) || defined(_WIN32) || defined(__ANDROID__) || \
     defined(__NetBSD__) || defined(__OpenBSD__)) && !defined(__FreeBSD__)
#ifndef fgets_unlocked
#define fgets_unlocked(buf, size, fp) fgets(buf, size, fp)
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

/* --- macOS POSIX scheduling -------------------------------------------------
 * macOS lacks SCHED_BATCH/SCHED_IDLE and sched_setscheduler(); stub them for
 * libprocessgroup task_profiles.cpp (the calls are inert on macOS). */
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

/* --- Windows socket constants -----------------------------------------------
 * SHUT_RD/WR/RDWR don't exist in MinGW's <sys/socket.h>; adb and others use them. */
#if defined(_WIN32)
#ifndef SHUT_RD
#define SHUT_RD SD_RECEIVE
#endif
#ifndef SHUT_WR
#define SHUT_WR SD_SEND
#endif
#ifndef SHUT_RDWR
#define SHUT_RDWR SD_BOTH
#endif
#endif

/* --- Windows stat() macros --------------------------------------------------
 * MinGW omits S_ISLNK/S_ISSOCK; provide them for libselinux (stringrep.c,
 * label_file.h). ADB TUs (ADB_HOST) are excluded for S_IFLNK/S_ISLNK/lstat —
 * adb/sysdeps/stat.h owns those, and pre-defining here would trip
 * -Wmacro-redefined when it redefines them bare. */
#if defined(_WIN32)
/* S_IFSOCK is not defined by adb's stat.h, so always provide it */
#ifndef S_IFSOCK
#define S_IFSOCK 0xC000
#endif
#ifndef S_ISSOCK
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)
#endif
/* S_IFLNK, S_ISLNK, lstat: skip for ADB TUs — sysdeps/stat.h owns these */
#if !defined(ADB_HOST)
#ifndef S_IFLNK
#define S_IFLNK 0xA000
#endif
#ifndef S_ISLNK
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)
#endif
/* Map lstat -> stat (a macro, so it inherits MinGW's _FILE_OFFSET_BITS=64
 * stat->_stat64 remap that an inline wrapper wouldn't). */
#ifndef lstat
#define lstat stat
#endif
#endif /* !ADB_HOST */
#endif

/* --- getline() --------------------------------------------------------------
 * MinGW lacks POSIX getline(); simple fallback for libselinux et al. */
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

/* --- TEMP_FAILURE_RETRY -----------------------------------------------------
 * glibc/bionic macro (retry a syscall on EINTR) AOSP uses unconditionally. glibc
 * and bionic define it *unguarded*, so don't pre-define there (would warn); supply
 * it only on macOS/MinGW/musl/BSD. (errno resolves at the expansion site.) */
#if defined(__APPLE__) || defined(_WIN32) || \
    defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || \
    (defined(__linux__) && !defined(__GLIBC__) && !defined(__ANDROID__))
#ifndef TEMP_FAILURE_RETRY
#define TEMP_FAILURE_RETRY(expression) (({ long int __result; do __result = (long int)(expression); while (__result == -1 && errno == EINTR); __result; }))
#endif
#endif

/* --- reallocarray() ---------------------------------------------------------
 * libsepol builds -DHAVE_REALLOCARRAY (skips its own decl), but macOS/MinGW may
 * lack a libc one; provide a fallback there (bionic gates on API 29). glibc, musl
 * and all BSDs declare it themselves, so they're excluded to avoid a clash. */
#if (!defined(__ANDROID_API__) || __ANDROID_API__ < 29) \
    && !defined(__GLIBC__) \
    && !(defined(__linux__) && !defined(__ANDROID__)) \
    && !defined(__FreeBSD__) && !defined(__NetBSD__) && !defined(__OpenBSD__)
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

/* --- bionic / Android NDK fallbacks ----------------------------------------- */
#if defined(__ANDROID__)

/* hasmntopt(): bionic API 26+; e2fsprogs ismounted.c uses it. */
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

/* getlogin_r(): bionic API 28+; adb's sysdeps.h uses it. */
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

/* --- Windows POSIX identity stubs -------------------------------------------
 * e2fsprogs blkid/cache.c safe_getenv() calls getuid/geteuid/getgid/getegid;
 * Windows has no such concept, so return 0 (not setuid/setgid). */
#if defined(_WIN32)
static inline uid_t getuid(void) { return 0; }
static inline uid_t geteuid(void) { return 0; }
static inline gid_t getgid(void) { return 0; }
static inline gid_t getegid(void) { return 0; }
#endif

/* --- Windows makedev/major/minor --------------------------------------------
 * llvm-mingw ships no <sys/sysmacros.h>; e2fsprogs blkid/devname.c uses makedev()
 * in dead Linux-only paths. config.h's HAVE_SYS_SYSMACROS_H is suppressed for
 * _WIN32 (see patch-source.sh), so provide the macros here. */
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

/* --- Windows malloc_usable_size ---------------------------------------------
 * sqlite3 builds -DHAVE_MALLOC_USABLE_SIZE everywhere; the Windows CRT's
 * equivalent is _msize(). Wrap it (a forward decl would leave an unresolved
 * symbol); _msize(NULL) is UB, so return 0 like glibc. */
#if defined(_WIN32) && !defined(malloc_usable_size)
#include <malloc.h>
static inline __attribute__((__unused__))
size_t malloc_usable_size(void *ptr) { return ptr ? _msize(ptr) : 0; }
#endif

/* --- OpenBSD malloc_usable_size stub ----------------------------------------
 * OpenBSD's malloc has no malloc_usable_size(); sqlite3 calls it for accounting,
 * so return 0 (just disables an oversized-block optimization). */
#if defined(__OpenBSD__) && !defined(malloc_usable_size)
#include <stddef.h>
static inline __attribute__((__unused__))
size_t malloc_usable_size(void *ptr) { (void)ptr; return 0; }
#endif

#endif /* HOST_COMPAT_H */
