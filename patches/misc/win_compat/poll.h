/* Minimal <poll.h> shim for the Windows (mingw) host build.
 *
 * AOSP's libselinux includes <poll.h> unconditionally (e.g. avc_internal.c),
 * but the actual poll()-based netlink/AVC code is compiled out under BUILD_HOST
 * -- so on a host build only the #include itself needs satisfying. mingw ships
 * no <poll.h>, so provide the types/constants (and a declaration) here. This is
 * placed on libselinux's include path for PLATFORM_WINDOWS only.
 */
#ifndef ANDROID_SDK_WIN_COMPAT_POLL_H
#define ANDROID_SDK_WIN_COMPAT_POLL_H

typedef unsigned long nfds_t;

struct pollfd {
    int   fd;
    short events;
    short revents;
};

#define POLLIN   0x0001
#define POLLPRI  0x0002
#define POLLOUT  0x0004
#define POLLERR  0x0008
#define POLLHUP  0x0010
#define POLLNVAL 0x0020

#ifdef __cplusplus
extern "C"
#endif
int poll(struct pollfd *fds, nfds_t nfds, int timeout);

#endif /* ANDROID_SDK_WIN_COMPAT_POLL_H */
