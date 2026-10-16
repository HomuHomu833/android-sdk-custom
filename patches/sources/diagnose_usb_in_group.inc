// Spliced into older diagnose_usb.cpp (platform-tools 32.0.0 and earlier) by
// patch-source.sh: it calls GNU group_member(), which only glibc and bionic
// have. Check the supplementary groups directly instead.
#if defined(__linux__) && !defined(__BIONIC__)
#include <vector>
static bool sdk_in_group(gid_t gid) {
    int n = getgroups(0, nullptr);
    if (n <= 0) return false;
    std::vector<gid_t> groups(n);
    n = getgroups(n, groups.data());
    for (int i = 0; i < n; ++i) {
        if (groups[i] == gid) return true;
    }
    return false;
}
#endif

