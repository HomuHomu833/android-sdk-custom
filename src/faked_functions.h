#ifndef FAKED_FUNCTIONS_H
#define FAKED_FUNCTIONS_H

#include <cstdint>

#if !defined(__BIONIC__)
// Host builds have no Android property system, so faked_functions.cpp backs the
// property API with an in-process fake store keyed off this concrete prop_info.
// On bionic the device's real libc property system is used instead, where
// prop_info is an opaque libc type — so this definition (and the host-only fakes)
// must not shadow it.
struct prop_info {
    char name[64];
    char value[256];
    uint32_t serial;
};

extern "C" {
    int __system_property_foreach(void (*propfn)(const prop_info* pi, void* cookie),
                                  void* cookie);

    void __system_property_read_callback(
        const prop_info* pi,
        void (*callback)(void* cookie, const char* name, const char* value, uint32_t serial),
        void* cookie);
}
#endif  // !__BIONIC__

extern "C" {
    int cacheflush(long start, long end, long flags);
}

#endif  // FAKED_FUNCTIONS_H
