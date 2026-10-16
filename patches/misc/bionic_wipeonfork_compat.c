// Pre-4.14 kernels reject MADV_WIPEONFORK (advice 18) with EINVAL, and the
// bionic arc4random bootstrap aborts on that ("arc4random data
// MADV_WIPEONFORK failed"). Emulate the wipe: remember every range that asked
// to be wiped, and make the fork child see it zeroed.
//
// The child is wiped with MADV_DONTNEED, not memset. For a MAP_PRIVATE |
// MAP_ANONYMOUS mapping MADV_DONTNEED drops the private pages and the next
// access faults in a fresh zero page -- the WIPEONFORK result -- while leaving
// the parent untouched, needing no page-aligned length, and faulting nothing
// if the range was unmapped in the meantime (it just returns ENOMEM). One
// syscall, safe in an atfork child.
//
// Registered unconditionally at init: bionic allocates its arc4random range
// lazily (on the first arc4random() call), i.e. after .init_array has run, so
// a "register only if a range exists" guard would never register and the child
// would inherit the parent's RNG state (PARENT == CHILD).
//
// Hot path: every madvise in the process (allocator advice 1/3, etc.) must
// reach the real call untouched. The advice check runs first and the wrapper is
// kept frameless by moving the advice-18 handling into a noinline helper --
// measured on this toolchain, `advice != 18` is `cmp`/`b.ne` straight to a tail
// branch, with no stack frame and no TLS __errno() call. Only advice 18, about
// once per process, pays for the frame and the errno handling below.
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>

#ifndef MADV_WIPEONFORK
#define MADV_WIPEONFORK 18
#endif

int __real_madvise(void*, size_t, int);

// Static list: no allocation from the wrapper (called from libc init paths) and
// none from the atfork child. .bss is SHT_NOBITS -- it costs no bytes in the
// file, only zeroed-at-startup memory, so the cap is set on safety grounds, not
// size: 64 is far beyond bionic's single arc4random mapping. Past the cap the
// abort is still suppressed; only recording stops.
#define MAX_REGIONS 64
static struct { void* p; size_t n; } regions[MAX_REGIONS];
static unsigned nregions;

static void wipe_child(void) {
  for (unsigned i = 0; i < nregions; i++)
    __real_madvise(regions[i].p, regions[i].n, MADV_DONTNEED);
}

static void wipeonfork_compat_init(void) {
  pthread_atfork(NULL, NULL, wipe_child);
}
__attribute__((section(".init_array"), used))
static void (*wipeonfork_compat_init_entry)(void) = wipeonfork_compat_init;

// Out of line on purpose: keeps __wrap_madvise a frameless dispatcher. errno is
// saved and restored so a suppressed failure stays invisible to the caller.
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
  // Report success even when we could not record: bionic turns a failure here
  // into __libc_fatal, and running with an unwiped child beats aborting.
  errno = saved;
  return 0;
}

int __wrap_madvise(void* addr, size_t len, int advice) {
  if (advice != MADV_WIPEONFORK)
    return __real_madvise(addr, len, advice);
  return wrap_madvise_wipeonfork(addr, len);
}
