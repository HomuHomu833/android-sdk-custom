/* Force-included for the macOS (osxcross) libselinux host build.
 *
 * The selabel backend selinux uses on a host (label_file.c) already special-cases
 * __APPLE__ for its extended-attribute calls, so no xattr remapping is needed
 * here -- the device-side *filecon sources that use the bare Linux xattr API are
 * excluded from the macOS build instead (see lib/libselinux.cmake). All that's
 * left is O_PATH, which macOS lacks; selinux only uses it to test an fd's flags,
 * a no-op on a host build.
 */
#ifndef ANDROID_SDK_MAC_SELINUX_COMPAT_H
#define ANDROID_SDK_MAC_SELINUX_COMPAT_H

#include <fcntl.h>

#ifndef O_PATH
#define O_PATH 0
#endif

#endif /* ANDROID_SDK_MAC_SELINUX_COMPAT_H */
