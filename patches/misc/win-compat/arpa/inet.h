/* Minimal <arpa/inet.h> for the llvm-mingw (Windows) host build.
 *
 * llvm-mingw ships no <arpa/inet.h> (it is a POSIX/sockets header; Windows
 * exposes the same byte-order helpers through <winsock2.h> instead).
 * e2fsprogs' lib/ext2fs/jfs_compat.h includes <arpa/inet.h> unconditionally
 * (not behind a HAVE_* guard, so it cannot be suppressed via config.h) purely
 * for the network byte-order helpers used by the journal code.
 *
 * Provide just those helpers.  Windows is always little-endian, so network
 * (big-endian) order is a straight byte swap.  This mirrors e2fsprogs' own
 * include/mingw/arpa/inet.h; we keep a private copy rather than putting that
 * directory on the include path because its sibling headers (unistd.h, etc.)
 * redefine getuid()/getgid() as macros that clash with the inline stubs in
 * patches/misc/host_compat.h.
 *
 * Scope: only e2fsprogs' journal code pulls in <arpa/inet.h> on Windows, and
 * it does not include <winsock2.h>, so these macros do not collide with the
 * winsock declarations of the same names.
 */
#ifndef HOST_COMPAT_ARPA_INET_H
#define HOST_COMPAT_ARPA_INET_H

#ifndef htonl
#define htonl(x) __builtin_bswap32(x)
#endif
#ifndef ntohl
#define ntohl(x) __builtin_bswap32(x)
#endif
#ifndef htons
#define htons(x) __builtin_bswap16(x)
#endif
#ifndef ntohs
#define ntohs(x) __builtin_bswap16(x)
#endif

#endif /* HOST_COMPAT_ARPA_INET_H */
