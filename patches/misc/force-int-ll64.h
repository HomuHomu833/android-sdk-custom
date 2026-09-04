/* force-int-ll64.h: some 64-bit arches' <asm/types.h> selects
 * asm-generic/int-l64.h, which defines __s64/__u64 as 'long'.  Most userspace
 * code (e2fsprogs, libblkid, etc.) expects 'long long' for these types and
 * hard-codes 'unsigned long long' in struct fields and function-pointer
 * typedefs.  Mixing them causes typedef redefinition errors (same size,
 * different type token) and function-pointer type-mismatch errors at the
 * assignment sites.
 *
 * Affected here: MIPS64 LP64 (n64 ABI) and 64-bit PowerPC — the kernel uapi
 * headers pick int-l64.h for both.  It only surfaces under glibc, whose
 * <sys/stat.h> reaches asm/types.h via bits/statx.h -> linux/stat.h ->
 * linux/types.h; the musl sysroots never take that include path.
 *
 * Solution: pre-empt int-l64.h by defining its include guard before the kernel
 * headers pull it in, then provide ALL eight basic kernel integer types with the
 * same definitions as asm-generic/int-ll64.h (used by x86_64, aarch64, etc.)
 * — only the 64-bit pair changes from 'long' to 'long long'.  On LP64 both
 * spellings are 64-bit, so the ABI is identical; only the type name differs.
 * All code in a TU therefore sees a consistent 'unsigned long long' for
 * __u64/blk64_t/etc., eliminating both error classes.
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
