#include "faked_functions.h"

#include <cstdint>
#include <cstring>
#include <string>
#include <mutex>

#if defined(__BIONIC__)

// On Android the device's real property system is used (faked_functions.h compiles
// the host fake store out). minSdk < 26 can't link the API-26 property helpers
// (__system_property_read_callback / _wait / _serial / _area_serial), so provide
// compat shims implemented over the API-1 primitives that already exist at API 25.
// Property *reads* work correctly; the serial-based change tracking degrades to a
// no-op (pre-26 libc exposes no public way to read serials), which only affects
// the rarely used WaitForProperty path in these host tools. The repo's ungated
// <sys/system_properties.h> (added to the include path for bionic in build.sh)
// supplies the matching declarations so the rest of the tree compiles.
#include <sys/system_properties.h>
#include <android/fdsan.h>
#include <unistd.h>

#if __ANDROID_API__ < 26
extern "C" {
    void __system_property_read_callback(
        const prop_info* pi,
        void (*callback)(void* cookie, const char* name, const char* value, uint32_t serial),
        void* cookie) {
        char name[PROP_NAME_MAX] = {};
        char value[PROP_VALUE_MAX] = {};
        int len = __system_property_read(pi, name, value);
        if (len >= 0) {
            callback(cookie, name, value, 0);
        }
    }

    uint32_t __system_property_serial(const prop_info* /*pi*/) { return 0; }

    uint32_t __system_property_area_serial(void) { return 0; }

    bool __system_property_wait(const prop_info* /*pi*/, uint32_t /*old_serial*/,
                                uint32_t* new_serial_ptr,
                                const struct timespec* /*relative_timeout*/) {
        if (new_serial_ptr) *new_serial_ptr = 0;
        return false;  // no change-notification primitive before API 26
    }
}
#endif  // __ANDROID_API__ < 26

// fdsan (file-descriptor sanitizer, API 29) owner-tag helpers. libcutils
// native_handle.cpp calls some of these *unguarded*, so they can't be weak-linked
// (null call -> crash on pre-29 devices). fdsan is a debug-only aid, so stub it out
// to no-ops: always present, safe on every API. <android/fdsan.h> is the ungated
// shim that supplies the matching declarations + the owner_type enum.
#if __ANDROID_API__ < 29
extern "C" {
    uint64_t android_fdsan_create_owner_tag(enum android_fdsan_owner_type /*type*/,
                                            uint64_t /*tag*/) { return 0; }

    void android_fdsan_exchange_owner_tag(int /*fd*/, uint64_t /*expected_tag*/,
                                          uint64_t /*new_tag*/) {}

    int android_fdsan_close_with_tag(int fd, uint64_t /*tag*/) { return close(fd); }

    uint64_t android_fdsan_get_owner_tag(int /*fd*/) { return 0; }
}
#endif  // __ANDROID_API__ < 29

#else  // !__BIONIC__ -- host builds back the property API with a fake store

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

#endif  // __BIONIC__

extern "C" {
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
