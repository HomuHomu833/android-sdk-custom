/* MIPS64 n64 and 64-bit PowerPC kernel headers type __s64/__u64 as 'long';
 * e2fsprogs et al hardcode 'long long', so their typedefs clash. Claim
 * int-l64.h's guard first and define int-ll64.h's types (same ABI on LP64).
 * -include'd for those Linux targets only (build.sh). */
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
