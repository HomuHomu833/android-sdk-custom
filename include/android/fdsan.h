#pragma once

// Ungated shim over the NDK's <android/fdsan.h>. The NDK gates the fdsan owner-tag
// functions behind API>=29, so a minSdk-25 build can't see them even though the
// AOSP code (libcutils native_handle.cpp, libbase unique_fd.h) calls them. Pull in
// the real header for the enum + (API>=29) declarations via include_next, then
// declare the functions unconditionally for API<29. faked_functions.cpp provides
// no-op stub definitions (fdsan is a debug-only fd sanitizer; disabling it is
// safe), so the calls link and run harmlessly on every API>=25 -- including the
// unguarded uses in native_handle.cpp, which a weak-symbol scheme would crash.
#if defined(__has_include_next) && __has_include_next(<android/fdsan.h>)
#include_next <android/fdsan.h>
#endif

#if defined(__BIONIC__) && __ANDROID_API__ < 29
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint64_t android_fdsan_create_owner_tag(enum android_fdsan_owner_type type, uint64_t tag);
void android_fdsan_exchange_owner_tag(int fd, uint64_t expected_tag, uint64_t new_tag);
int android_fdsan_close_with_tag(int fd, uint64_t tag);
uint64_t android_fdsan_get_owner_tag(int fd);
#ifdef __cplusplus
}
#endif
#endif
