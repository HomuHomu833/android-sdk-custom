// Force-included into every C++ compile on the zig toolchains (linux/bsd).
// AOSP code leans on headers its own libc++ pulled in transitively; the libc++
// of zig 0.18 no longer does (std::vector, std::back_inserter, std::atomic,
// std::for_each, ... "no member named ... in namespace 'std'"). Restore them.
#pragma once
#ifdef __cplusplus
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iterator>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#endif
