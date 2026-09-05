/* force-int-ll64.h: MIPS64 n64 and 64-bit PowerPC pick asm-generic/int-l64.h,
 * typing __s64/__u64 as 'long', while e2fsprogs et al hardcode 'long long' --
 * so typedefs and function pointers clash. glibc only: its <sys/stat.h> reaches
 * asm/types.h via bits/statx.h; the musl sysroots never do.
 *
 * Claim int-l64.h's include guard before the kernel headers get there, then
 * define all eight types as asm-generic/int-ll64.h does. Both spellings are
 * 64-bit on LP64, so only the type name changes, not the ABI.
 *
 * Force-included via -include for the affected glibc targets only. */
#ifndef _ASM_GENERIC_INT_L64_H
#define _ASM_GENERIC_INT_L64_H

#ifndef __ASSEMBLY__
typedef __signed__ char         __s8;
typedef unsigned char           __u8;

typedef __signed__ short        __s16;
typedef unsigned short          __u16;

typedef __signed__ int          __s32;
typedef unsigned int            __u32;

typedef __signed__ long long    __s64;
typedef unsigned long long      __u64;
#endif /* __ASSEMBLY__ */

#endif
