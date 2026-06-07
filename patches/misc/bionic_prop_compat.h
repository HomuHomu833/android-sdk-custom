#pragma once

// __system_property_serial() and __system_property_area_serial() are real bionic
// libc functions (exported by libc.so and the NDK link stub), but the NDK's
// property headers never *declare* them at any API level -- they're treated as
// internal. AOSP libbase properties.cpp calls both, so a plain NDK build fails to
// compile ("use of undeclared identifier"). Forward-declare them; the link resolves
// against libc. Force-included for the bionic build (see build.sh).
//
// NB: guard on __ANDROID__ (a compiler predefine), not __BIONIC__ (defined by
// bionic's <sys/cdefs.h>) -- this header is force-included before any system
// header, so __BIONIC__ isn't defined yet at this point.
#if defined(__ANDROID__)
#include <stdint.h>
struct prop_info;
#ifdef __cplusplus
extern "C" {
#endif
uint32_t __system_property_serial(const struct prop_info* __pi);
uint32_t __system_property_area_serial(void);
#ifdef __cplusplus
}
#endif
#endif  // __ANDROID__
