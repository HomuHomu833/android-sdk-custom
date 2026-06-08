/* Stub <dlfcn.h> for the Windows (mingw) libselinux host build.
 *
 * mingw has no dlopen/dlsym; selinux's init.c includes <dlfcn.h>. The dynamic
 * loading it guards is irrelevant on a host build, so provide stubs: dlopen
 * fails (returns NULL) and the rest are no-ops. Found via the win_compat dir on
 * libselinux's include path (PLATFORM_WINDOWS only).
 */
#ifndef ANDROID_SDK_WIN_COMPAT_DLFCN_H
#define ANDROID_SDK_WIN_COMPAT_DLFCN_H

#define RTLD_LAZY   0x1
#define RTLD_NOW    0x2
#define RTLD_LOCAL  0x4
#define RTLD_GLOBAL 0x8
#define RTLD_NODELETE 0x1000
#define RTLD_NOLOAD   0x4
#define RTLD_DEEPBIND 0x8

static inline __attribute__((__unused__))
void *dlopen(const char *__file, int __flag) { (void)__file; (void)__flag; return 0; }
static inline __attribute__((__unused__))
int dlclose(void *__handle) { (void)__handle; return 0; }
static inline __attribute__((__unused__))
void *dlsym(void *__handle, const char *__symbol) { (void)__handle; (void)__symbol; return 0; }
static inline __attribute__((__unused__))
char *dlerror(void) { return (char *)"dlfcn not supported on this host"; }

#endif /* ANDROID_SDK_WIN_COMPAT_DLFCN_H */
