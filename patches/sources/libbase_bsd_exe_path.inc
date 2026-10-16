// Spliced into libbase's file.cpp by patch-source.sh: GetExecutablePath() for
// the BSDs, which have no /proc/self/exe. adb execs this path to start its
// server, so it must be absolute, not just getprogname().
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
#include <sys/sysctl.h>
static std::string sdk_bsd_executable_path() {
#if defined(__FreeBSD__) || defined(__NetBSD__)
  char buf[PATH_MAX];
  size_t len = sizeof(buf);
#if defined(__FreeBSD__)
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1};
#else
  int mib[4] = {CTL_KERN, KERN_PROC_ARGS, -1, KERN_PROC_PATHNAME};
#endif
  if (sysctl(mib, 4, buf, &len, nullptr, 0) == 0 && len > 1) return std::string(buf);
#endif
  // OpenBSD (and a failed sysctl): resolve argv[0] the way the shell did.
  std::string arg0;
#if defined(__OpenBSD__)
  int amib[4] = {CTL_KERN, KERN_PROC_ARGS, getpid(), KERN_PROC_ARGV};
  size_t alen = 0;
  if (sysctl(amib, 4, nullptr, &alen, nullptr, 0) == 0 && alen > 0) {
    std::vector<char> abuf(alen);
    if (sysctl(amib, 4, abuf.data(), &alen, nullptr, 0) == 0) {
      char** argv = reinterpret_cast<char**>(abuf.data());
      if (argv[0] != nullptr) arg0 = argv[0];
    }
  }
#endif
  if (arg0.empty()) arg0 = getprogname();
  char resolved[PATH_MAX];
  if (arg0.find('/') != std::string::npos) {
    if (realpath(arg0.c_str(), resolved) != nullptr) return resolved;
    return arg0;
  }
  const char* env = getenv("PATH");
  std::string paths = env ? env : "/usr/bin:/bin";
  size_t start = 0;
  while (start <= paths.size()) {
    size_t end = paths.find(':', start);
    if (end == std::string::npos) end = paths.size();
    std::string dir = paths.substr(start, end - start);
    std::string cand = (dir.empty() ? "." : dir) + "/" + arg0;
    if (access(cand.c_str(), X_OK) == 0 && realpath(cand.c_str(), resolved) != nullptr)
      return resolved;
    start = end + 1;
  }
  return arg0;
}
#endif
