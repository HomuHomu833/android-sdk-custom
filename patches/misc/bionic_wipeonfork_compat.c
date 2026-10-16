// Pre-4.14 kernels reject MADV_WIPEONFORK with EINVAL; newer bionic arc4random
// aborts on that. Emulate it: remember the range, drop it in the fork child.
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>

#ifndef MADV_WIPEONFORK
#define MADV_WIPEONFORK 18
#endif

#define MAX_REGIONS 64

int __real_madvise(void*, size_t, int);

static struct { void* p; size_t n; } regions[MAX_REGIONS];
static unsigned nregions;
// MADV_DONTNEED on private anonymous memory gives the child fresh zero pages,
// and is harmless if the range was unmapped in the meantime.
static void wipe_child(void) {
  for (unsigned i = 0; i < nregions; i++)
    __real_madvise(regions[i].p, regions[i].n, MADV_DONTNEED);
}

// Register unconditionally: bionic's arc4random calls madvise lazily, after
// constructors have run, so no range is recorded yet at this point.
static void wipeonfork_compat_init(void) {
  pthread_atfork(NULL, NULL, wipe_child);
}
__attribute__((section(".init_array"), used))
static void (*wipeonfork_compat_init_entry)(void) = wipeonfork_compat_init;

// Kept out of line so __wrap_madvise stays a cheap pass-through for other advice.
__attribute__((noinline))
static int wrap_madvise_wipeonfork(void* addr, size_t len) {
  int saved = errno;

  if (__real_madvise(addr, len, MADV_WIPEONFORK) == 0)
    return 0;

  if (errno == EINVAL && nregions < MAX_REGIONS) {
    regions[nregions].p = addr;
    regions[nregions].n = len;
    nregions++;
  }

  // Always report success: bionic aborts on failure here.
  errno = saved;
  return 0;
}

int __wrap_madvise(void* addr, size_t len, int advice) {
  if (advice != MADV_WIPEONFORK)
    return __real_madvise(addr, len, advice);

  return wrap_madvise_wipeonfork(addr, len);
}
