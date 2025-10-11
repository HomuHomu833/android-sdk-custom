#ifndef FAKED_FUNCTIONS_H
#define FAKED_FUNCTIONS_H

#include <cstdint>

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

    int cacheflush(long start, long end, long flags);
}

#endif  // FAKED_FUNCTIONS_H
