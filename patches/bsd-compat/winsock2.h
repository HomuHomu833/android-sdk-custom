/* BSD compat stub: android-base/endian.h falls into a !__linux__ && !__APPLE__
 * branch that includes winsock2.h for htons/htonl/ntohs/ntohl.  On BSD those
 * live in <netinet/in.h>, which host_compat.h already includes.  This stub
 * prevents a hard "file not found" error. */
#pragma once
#include <netinet/in.h>   /* htons, htonl, ntohs, ntohl */
