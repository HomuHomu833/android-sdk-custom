/* Force-included for the macOS (osxcross) libselinux host build.
 *
 * The selabel backend selinux uses on a host (label_file.c) already special-cases
 * __APPLE__ for its extended-attribute calls, so no xattr remapping is needed
 * here -- the device-side *filecon sources that use the bare Linux xattr API are
 * excluded from the macOS build instead (see lib/libselinux.cmake). Two things
 * are left: O_PATH, which macOS lacks; and the Linux mount(2)/umount API that
 * load_policy.c uses to mount selinuxfs -- something that never happens on a
 * host build.
 */
#ifndef ANDROID_SDK_MAC_SELINUX_COMPAT_H
#define ANDROID_SDK_MAC_SELINUX_COMPAT_H

#include <errno.h>
#include <fcntl.h>

#ifndef O_PATH
#define O_PATH 0
#endif

/* load_policy.c calls the Linux mount API: 5-arg mount(2), umount(), umount2(),
 * and MS_NOEXEC/MS_NOSUID. macOS only provides the 4-arg BSD mount()/unmount()
 * and none of these flags. The whole selinuxfs/proc mounting path is inert on a
 * host build, so map the flags to 0 and redirect the calls to a failing stub.
 *
 * Pull in the real sys/mount.h FIRST (before defining the macros below) so its
 * own 4-arg mount() prototype is emitted normally; the source file later
 * includes sys/mount.h again, hits the include guard, and is skipped -- so the
 * function-like macros below only ever rewrite the actual call sites, never a
 * declaration. */
#include <sys/param.h>
#include <sys/mount.h>

#ifndef MS_NOSUID
#define MS_NOSUID 0
#endif
#ifndef MS_NOEXEC
#define MS_NOEXEC 0
#endif

static inline __attribute__((__unused__))
int android_sdk_selinux_mount_stub(void) {
  errno = ENOSYS;
  return -1;
}

#define mount(...)   android_sdk_selinux_mount_stub()
#define umount(...)  android_sdk_selinux_mount_stub()
#define umount2(...) android_sdk_selinux_mount_stub()

#endif /* ANDROID_SDK_MAC_SELINUX_COMPAT_H */
