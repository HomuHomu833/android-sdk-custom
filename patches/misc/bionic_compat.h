#pragma once

// Force-included for the bionic (Android) host-tool build (see build.sh). bionic's
// libc lacks the glibc/musl GNU stdio "*_unlocked" extensions (it only ships the
// POSIX getc/putc/getchar/putchar variants), but AOSP host code such as selinux's
// label_file.c uses them as a single-threaded perf optimization. The _unlocked
// forms differ from the plain ones only in skipping the per-FILE lock, so mapping
// them to the locked equivalents is functionally identical here.
#if defined(__ANDROID__)
#ifndef fgets_unlocked
#define fgets_unlocked(s, n, f)      fgets((s), (n), (f))
#endif
#ifndef fputs_unlocked
#define fputs_unlocked(s, f)         fputs((s), (f))
#endif
#ifndef fread_unlocked
#define fread_unlocked(p, sz, n, f)  fread((p), (sz), (n), (f))
#endif
#ifndef fwrite_unlocked
#define fwrite_unlocked(p, sz, n, f) fwrite((p), (sz), (n), (f))
#endif
#ifndef fgetc_unlocked
#define fgetc_unlocked(f)            fgetc((f))
#endif
#ifndef fputc_unlocked
#define fputc_unlocked(c, f)         fputc((c), (f))
#endif
#ifndef fflush_unlocked
#define fflush_unlocked(f)           fflush((f))
#endif
#endif  // __ANDROID__
