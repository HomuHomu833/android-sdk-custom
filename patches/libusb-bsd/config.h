/* config.h for BSD (FreeBSD/NetBSD/OpenBSD) — POSIX backend, no Linux-specific APIs.
 * Generated manually from the linux/config.h template; Linux-only features
 * (eventfd, timerfd, udev, EFD_*/TFD_* flags) are disabled. */

#define DEFAULT_VISIBILITY __attribute__((visibility("default")))

/* #undef ENABLE_DEBUG_LOGGING */
#define ENABLE_LOGGING 1

/* #undef HAVE_ASM_TYPES_H */
#define HAVE_CLOCK_GETTIME 1

/* BSD has no eventfd/timerfd */
/* #undef HAVE_DECL_EFD_CLOEXEC */
/* #undef HAVE_DECL_EFD_NONBLOCK */
/* #undef HAVE_DECL_TFD_CLOEXEC */
/* #undef HAVE_DECL_TFD_NONBLOCK */

#define HAVE_DLFCN_H 1
/* #undef HAVE_EVENTFD */
#define HAVE_INTTYPES_H 1
/* #undef HAVE_LIBUDEV */
#define HAVE_MEMORY_H 1
#define HAVE_NFDS_T 1
/* #undef HAVE_PIPE2 */
#define HAVE_PTHREAD_CONDATTR_SETCLOCK 1
/* #undef HAVE_PTHREAD_SETNAME_NP */
/* #undef HAVE_PTHREAD_THREADID_NP */
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
/* #undef HAVE_STRUCT_TIMESPEC */
/* #undef HAVE_SYSLOG */
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
/* #undef HAVE_TIMERFD */
#define HAVE_UNISTD_H 1

#define LT_OBJDIR ".libs/"
#define PACKAGE "libusb-1.0"
#define PACKAGE_BUGREPORT "libusb-devel@lists.sourceforge.net"
#define PACKAGE_NAME "libusb-1.0"
#define PACKAGE_STRING "libusb-1.0 1.0.24"
#define PACKAGE_TARNAME "libusb-1.0"
#define PACKAGE_URL "http://libusb.info"
#define PACKAGE_VERSION "1.0.24"
#define PLATFORM_POSIX 1
/* #undef PLATFORM_WINDOWS */
#define PRINTF_FORMAT(a, b) __attribute__ ((__format__ (__printf__, a, b)))
#define STDC_HEADERS 1
/* #undef USE_SYSTEM_LOGGING_FACILITY */
#define VERSION "1.0.24"
/* No _GNU_SOURCE on BSD */
/* #undef _WIN32_WINNT */
#ifndef __cplusplus
/* #undef inline */
#endif
