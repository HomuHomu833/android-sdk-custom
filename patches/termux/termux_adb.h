// termux-adb USB shim (bionic only) — namespace wrapper over libtermuxadb's C
// API. Sourced from nohajc/vendor-adb-patched@35.0.2, reconciled for 36.x adb.
//
// Runtime-gated: every wrapper checks the LIBUSB_TERMUX_IMPL env var (off by
// default) and falls back to the real libc/adb call when unset, so the shipped
// adb behaves exactly like stock unless a (typically non-rooted Termux) user
// opts in with LIBUSB_TERMUX_IMPL=1.
#pragma once

#include <android-base/file.h>
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
    void termuxadb_start();
}

namespace termuxadb {
    // Cached LIBUSB_TERMUX_IMPL check: enabled when set to a non-empty, non-"0"
    // value. The env can't change mid-run, so cache after the first lookup.
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

    static inline int unix_open(std::string_view path, int options, ...) {
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

    static inline int adb_close(int fd) {
        return enabled() ? termuxadb_close(fd) : ::close(fd);
    }

    static inline int unix_close(int fd) {
        return enabled() ? termuxadb_close(fd) : ::close(fd);
    }

    static inline bool sendfd() {
        return enabled() ? termuxadb_sendfd() : false;
    }

    static inline void start() {
        if (enabled()) termuxadb_start();
    }

    static inline bool ReadFileToString(const std::string& path, std::string* content, bool follow_symlinks = false) {
        if (!enabled()) {
            return android::base::ReadFileToString(path, content, follow_symlinks);
        }
        content->clear();
        int flags = O_RDONLY | O_CLOEXEC | O_BINARY | (follow_symlinks ? 0 : O_NOFOLLOW);
        android::base::unique_fd fd(TEMP_FAILURE_RETRY(termuxadb_open(path.c_str(), flags)));
        if (fd == -1) {
            return false;
        }
        return ReadFdToString(fd, content);
    }
}
