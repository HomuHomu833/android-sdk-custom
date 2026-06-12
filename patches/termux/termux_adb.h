// termux-adb USB shim (bionic) — namespace wrapper over libtermuxadb's C API
// (nohajc/vendor-adb-patched@35.0.2, ported to 36.x). Gating is in the Rust shim
// (LIBUSB_TERMUX_IMPL, off by default → termuxadb_* delegate to libc), not via
// ::open/::close here, since those are bionic fortify macros.
#pragma once

#include <android-base/file.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
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

    // unix_close is `#define`d to adb_close in adb's sysdeps.h, so call sites land
    // here; defining unix_close too would redefine adb_close.
    static inline int adb_close(int fd) { return termuxadb_close(fd); }
    static inline bool sendfd() { return termuxadb_sendfd(); }
    static inline void start() { termuxadb_start(); }

    static inline bool ReadFileToString(const std::string& path, std::string* content, bool follow_symlinks = false) {
        content->clear();
        int flags = O_RDONLY | O_CLOEXEC | O_BINARY | (follow_symlinks ? 0 : O_NOFOLLOW);
        android::base::unique_fd fd(TEMP_FAILURE_RETRY(termuxadb_open(path.c_str(), flags)));
        if (fd == -1) {
            return false;
        }
        return ReadFdToString(fd, content);
    }
}
