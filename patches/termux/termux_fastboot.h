// termux-fastboot USB shim (bionic only) — namespace wrapper over libtermuxadb's
// C API (fastboot variant: plain open/close, fastboot_start). Ported for 36.x.
//
// Runtime-gated on LIBUSB_TERMUX_IMPL (off by default): start()/sendfd() are
// no-ops and the wrappers fall back to libc when unset, so stock fastboot is
// unchanged. usb_linux.cpp dispatches to the termux /dev/bus/usb walk only when
// enabled() (otherwise it keeps 36.x's sysfs scan).
#pragma once

#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <unistd.h>

#include <string>

extern "C" {
    DIR *termuxadb_opendir(const char *name);
    int termuxadb_closedir(DIR *dirp);
    struct dirent *termuxadb_readdir(DIR *dirp);

    int termuxadb_open(const char* path, int options);
    int termuxadb_create(const char* path, int options, int mode);
    int termuxadb_close(int fd);

    bool termuxadb_sendfd();
    void fastboot_start();
}

namespace termuxadb {
    static inline bool enabled() {
        static int e = -1;
        if (e < 0) {
            const char *v = ::getenv("LIBUSB_TERMUX_IMPL");
            e = (v && v[0] && !(v[0] == '0' && v[1] == '\0')) ? 1 : 0;
        }
        return e == 1;
    }

    static inline DIR *opendir(const char *name) {
        return enabled() ? termuxadb_opendir(name) : ::opendir(name);
    }

    static inline int closedir(DIR *dirp) {
        return enabled() ? termuxadb_closedir(dirp) : ::closedir(dirp);
    }

    static inline struct dirent *readdir(DIR *dirp) {
        return enabled() ? termuxadb_readdir(dirp) : ::readdir(dirp);
    }

    static inline int open(std::string_view path, int options, ...) {
        std::string p(path.begin(), path.end());
        if ((options & O_CREAT) == 0) {
            return TEMP_FAILURE_RETRY(enabled() ? termuxadb_open(p.c_str(), options)
                                                : ::open(p.c_str(), options));
        }
        int mode;
        va_list args;
        va_start(args, options);
        mode = va_arg(args, int);
        va_end(args);
        return TEMP_FAILURE_RETRY(enabled() ? termuxadb_create(p.c_str(), options, mode)
                                            : ::open(p.c_str(), options, mode));
    }

    static inline int close(int fd) {
        return enabled() ? termuxadb_close(fd) : ::close(fd);
    }

    static inline bool sendfd() {
        return enabled() ? termuxadb_sendfd() : false;
    }

    static inline void start() {
        if (enabled()) fastboot_start();
    }
}
