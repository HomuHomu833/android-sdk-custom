/*
 * Bionic allocates an 8-word TCB starting at the thread pointer, so on arm and
 * arm64 an executable's PT_TLS must be aligned to 8 words (32 / 64 bytes) for
 * its segment to clear those slots. Otherwise the loader aborts at startup:
 *
 *   error: "<prog>": executable's TLS segment is underaligned: alignment is 8
 *   (skew 0), needs to be at least 64 for ARM64 Bionic
 *
 * (bionic/libc/bionic/bionic_elf_tls.cpp, reserve_exe_segment_and_tcb).
 *
 * Bionic's crtbegin.c emits exactly this overalignment, but only under
 * __ANDROID_API__ >= 29, and the bionic tools target API 25 - so supply it
 * ourselves. Linked into every bionic executable (see scripts/build.sh); a no-op
 * object on the architectures/API levels that don't need it.
 *
 * The .reloc keeps .tdata alive if anything ever links with --gc-sections,
 * matching what crtbegin does.
 */
#if __ANDROID_API__ < 29
#if defined(__arm__)
  .section .tdata,"awT",%progbits
  .p2align 5
  .text
  .reloc 0, R_ARM_NONE, .tdata
#elif defined(__aarch64__)
  .section .tdata,"awT",@progbits
  .p2align 6
  .text
  .reloc 0, R_AARCH64_NONE, .tdata
#endif
#endif
