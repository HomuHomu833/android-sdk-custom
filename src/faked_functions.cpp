#include "faked_functions.h"

#include <cstdint>
#include <cstring>
#include <string>
#include <mutex>

#if !defined(__BIONIC__)
// Host builds (linux/musl/gnu) have no Android property system, so back the
// property API with an in-process fake store. On bionic the device's real libc
// property system is used, so none of this is compiled.

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
}

#endif  // !__BIONIC__

#if defined(__BIONIC__)
// The bionic host tools target a low API (default 25), whose NDK stub libc does
// not export every property symbol the AOSP sources reference:
//   __system_property_read_callback -- API 26 (libbase GetProperty, sysprop gen)
//   __system_property_wait          -- API 26 (libbase WaitForProperty)
//   __system_properties_init        -- libc-private (selinux android_device.c)
// Provide weak fallbacks so the tools link at API 25. read_callback is backed by
// the long-available __system_property_read(); property-wait degrades to an
// immediate timeout; init is a no-op (libc auto-initialises on first use).
#include <time.h>
#include <sys/system_properties.h>

extern "C" {
    __attribute__((weak))
    void __system_property_read_callback(
        const prop_info* pi,
        void (*callback)(void* cookie, const char* name, const char* value, uint32_t serial),
        void* cookie) {
        char name[PROP_NAME_MAX];
        char value[PROP_VALUE_MAX];
        int len = __system_property_read(pi, name, value);
        if (len >= 0) {
            callback(cookie, name, value, 0);
        }
    }

    __attribute__((weak))
    bool __system_property_wait(const prop_info* /*pi*/, uint32_t /*old_serial*/,
                                uint32_t* /*new_serial_ptr*/,
                                const struct timespec* /*relative_timeout*/) {
        return false;
    }

    __attribute__((weak))
    int __system_properties_init(void) {
        return 0;
    }
}

#endif  // __BIONIC__

extern "C" {
    __attribute__((weak))
    int cacheflush(long start, long end, long flags) {
        (void)flags;

    #if !defined(__s390x__) && !defined(__ppc__) && !defined(__hexagon__)
        __builtin___clear_cache(reinterpret_cast<char*>(start),
                                reinterpret_cast<char*>(end));
    #else
        (void)start;
        (void)end;
    #endif

        return 0;
    }
}
