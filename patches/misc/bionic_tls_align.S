/* Bionic's 8-word TCB needs arm/arm64 executables' PT_TLS aligned to 32/64
 * bytes, or the loader aborts ("TLS segment is underaligned"). crtbegin only
 * emits that from API 29, below the bionic tools' target, so supply it here;
 * the .reloc keeps .tdata alive under --gc-sections, as crtbegin does. */
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
