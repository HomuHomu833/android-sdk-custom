// Pre-4.14 kernels reject MADV_WIPEONFORK with EINVAL; newer bionic arc4random
// aborts on that. Emulate it: remember the range, zero it in the fork child.
#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#ifndef MADV_WIPEONFORK
#define MADV_WIPEONFORK 18
#endif
int __real_madvise(void*, size_t, int);
#define MAX_REGIONS 8
static struct { void* p; size_t n; } regions[MAX_REGIONS];
static int nregions;
static void wipe_child(void) {
  for (int i = 0; i < nregions; i++) memset(regions[i].p, 0, regions[i].n);
}
static void wipeonfork_compat_init(void) {
  if (nregions) pthread_atfork(NULL, NULL, wipe_child);
}
__attribute__((section(".init_array"), used))
static void (*wipeonfork_compat_init_entry)(void) = wipeonfork_compat_init;
int __wrap_madvise(void* addr, size_t len, int advice) {
  int saved = errno;
  int r = __real_madvise(addr, len, advice);
  if (r == -1 && errno == EINVAL && advice == MADV_WIPEONFORK &&
      nregions < MAX_REGIONS) {
    regions[nregions].p = addr;
    regions[nregions].n = len;
    nregions++;
    errno = saved;
    return 0;
  }
  return r;
}