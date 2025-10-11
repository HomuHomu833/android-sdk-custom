#include "faked_functions.h"

#include <cstdint>
#include <cstring>
#include <string>
#include <mutex>

#define MAX_PROPERTIES 128
#define MAX_NAME_LEN   64
#define MAX_VALUE_LEN  256

static prop_info property_store[MAX_PROPERTIES];
static size_t property_count = 0;
static std::mutex property_mutex;

extern "C" {
    int __system_property_foreach(void (*propfn)(const prop_info* pi, void* cookie),
                                   void* cookie) {
        std::lock_guard<std::mutex> lock(property_mutex);

        for (size_t i = 0; i < property_count; ++i) {
            propfn(&property_store[i], cookie);
        }
        return 0;
    }

    void __system_property_read_callback(
        const prop_info* pi,
        void (*callback)(void* cookie, const char* name, const char* value, uint32_t serial),
        void* cookie) {

        callback(cookie, pi->name, pi->value, pi->serial);
    }

    int cacheflush(long start, long end, long flags) {
    #if defined(__linux__)
        __builtin___clear_cache((char*)start, (char*)end);
    #endif
        return 0;
    }
}
