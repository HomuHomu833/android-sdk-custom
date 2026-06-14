/* byteswap.h — BSD compat stub
 * <byteswap.h> is Linux/glibc-only.  BSDs provide equivalent swap functions
 * (bswap16/32/64) in <sys/endian.h>.  Map the glibc names to BSD names. */
#pragma once
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
# include <sys/endian.h>
#endif
#ifndef bswap_16
# define bswap_16 bswap16
#endif
#ifndef bswap_32
# define bswap_32 bswap32
#endif
#ifndef bswap_64
# define bswap_64 bswap64
#endif
