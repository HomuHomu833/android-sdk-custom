// termux-fastboot USB shim (bionic) — wrapper over libtermuxadb's C API (fastboot
// variant: fastboot_start). Gating is in the Rust shim (LIBUSB_TERMUX_IMPL, off by
// default → termuxadb_* delegate to libc); usb_linux.cpp uses enabled() to pick
// the termux /dev/bus/usb walk over the stock sysfs scan. Wrappers are unix_*
// (not open/close) to dodge bionic's fortify macros.
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
    // Cached LIBUSB_TERMUX_IMPL check; usb_linux.cpp uses it for the scan dispatch.
    static inline bool enabled() {
        static int e = -1;
        if (e < 0) {
            const char *v = ::getenv("LIBUSB_TERMUX_IMPL");
            e = (v && v[0] && !(v[0] == '0' && v[1] == '\0')) ? 1 : 0;
        }
        return e == 1;
    }

    static inline DIR *opendir(const char *name) { return termuxadb_opendir(name); }
    static inline int closedir(DIR *dirp) { return termuxadb_closedir(dirp); }
    static inline struct dirent *readdir(DIR *dirp) { return termuxadb_readdir(dirp); }

    static inline int unix_open(std::string_view path, int options, ...) {
        std::string zero_terminated(path.begin(), path.end());
        if ((options & O_CREAT) == 0) {
            return TEMP_FAILURE_RETRY(termuxadb_open(zero_terminated.c_str(), options));
        }
        int mode;
        va_list args;
        va_start(args, options);
        mode = va_arg(args, int);
        va_end(args);
        return TEMP_FAILURE_RETRY(termuxadb_create(zero_terminated.c_str(), options, mode));
    }

    static inline int unix_close(int fd) { return termuxadb_close(fd); }
    static inline bool sendfd() { return termuxadb_sendfd(); }
    static inline void start() { fastboot_start(); }
}
