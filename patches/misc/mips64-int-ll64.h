/* mips64-int-ll64.h: on MIPS64 LP64 (n64 ABI), asm-generic/int-l64.h
 * defines __s64/__u64 as 'long'.  Most userspace code (e2fsprogs, libblkid,
 * etc.) expects 'long long' for these types and hard-codes 'unsigned long long'
 * in struct fields and function-pointer typedefs.  Mixing them causes typedef
 * redefinition errors (same size, different type token) and function-pointer
 * type-mismatch errors at the assignment sites.
 *
 * Solution: pre-empt int-l64.h by defining its include guard before the kernel
 * headers pull it in, then provide ALL eight basic kernel integer types with the
 * same definitions as asm-generic/int-ll64.h (used by x86_64, aarch64, etc.)
 * — only the 64-bit pair changes from 'long' to 'long long'.  On LP64 MIPS
 * both spellings are 64-bit, so the ABI is identical; only the type name
 * differs.  All code in a TU therefore sees a consistent 'unsigned long long'
 * for __u64/blk64_t/etc., eliminating both error classes.
 *
 * Force-included via -include for mips64*gnuabi64 glibc targets only. */
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
