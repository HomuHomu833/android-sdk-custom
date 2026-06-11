// BSD implementation of openscreen GetAllInterfaces().
//
// Derived from network_interface_mac.cc with BSD-specific adaptations:
//   - <netinet6/in6_var.h> instead of <netinet/in_var.h>
//   - ifru_flags6 (not ifru_flags) for SIOCGIFAFLAG_IN6 result
//   - LLADDR() cast to const uint8_t* (avoids caddr_t const-qualification
//     mismatch and the broken sizeof(pointer) static_assert)

#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_media.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>

// net/if.h must be included before this.
#include <ifaddrs.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include "platform/impl/network_interface.h"
#include "platform/base/ip_address.h"
#include "platform/impl/scoped_pipe.h"
#include "util/osp_logging.h"

namespace openscreen {

namespace {

template <size_t N>
uint8_t ToPrefixLength(const uint8_t (&netmask)[N]) {
  uint8_t result = 0;
  size_t i = 0;
  while (i < N && netmask[i] == UINT8_C(0xff)) {
    result += 8;
    ++i;
  }
  if (i < N && netmask[i] != UINT8_C(0x00)) {
    uint8_t last_byte = netmask[i];
    while (last_byte & UINT8_C(0x80)) {
      ++result;
      last_byte <<= 1;
    }
    OSP_CHECK(last_byte == UINT8_C(0x00));
    ++i;
  }
  while (i < N) {
    OSP_CHECK(netmask[i] == UINT8_C(0x00));
    ++i;
  }
  return result;
}

}  // namespace

std::vector<InterfaceInfo> GetAllInterfaces() {
  ifaddrs* interfaces = nullptr;
  if (getifaddrs(&interfaces) != 0) {
    return {};
  }

  // Socket used for querying interface media types and IPv6 address flags.
  const ScopedFd ioctl_socket(socket(AF_INET6, SOCK_DGRAM, 0));

  std::vector<InterfaceInfo> results;
  for (ifaddrs* cur = interfaces; cur; cur = cur->ifa_next) {
    if (!(IFF_RUNNING & cur->ifa_flags) || !cur->ifa_addr) {
      continue;
    }

    const std::string name = cur->ifa_name;
    const auto it = std::find_if(
        results.begin(), results.end(),
        [&name](const InterfaceInfo& info) { return info.name == name; });
    InterfaceInfo* interface;
    if (it == results.end()) {
      InterfaceInfo::Type type = InterfaceInfo::Type::kOther;
      ifmediareq ifmr;
      memset(&ifmr, 0, sizeof(ifmr));
      memcpy(ifmr.ifm_name, name.data(),
             std::min(name.size(), sizeof(ifmr.ifm_name) - 1));
      if (ioctl(ioctl_socket.get(), SIOCGIFMEDIA, &ifmr) >= 0) {
        if (!((ifmr.ifm_status & IFM_AVALID) &&
              (ifmr.ifm_status & IFM_ACTIVE))) {
          continue;
        }
        if (ifmr.ifm_current & IFM_IEEE80211) {
          type = InterfaceInfo::Type::kWifi;
        } else if (ifmr.ifm_current & IFM_ETHER) {
          type = InterfaceInfo::Type::kEthernet;
        }
      } else if (cur->ifa_flags & IFF_LOOPBACK) {
        type = InterfaceInfo::Type::kLoopback;
      } else {
        continue;
      }

      const uint8_t kUnknownHardwareAddress[6] = {0, 0, 0, 0, 0, 0};
      results.emplace_back(if_nametoindex(cur->ifa_name),
                           kUnknownHardwareAddress, name, type,
                           std::vector<IPSubnet>());
      interface = &(results.back());
    } else {
      interface = &(*it);
    }

    if (cur->ifa_addr->sa_family == AF_LINK) {
      auto* const addr_dl =
          reinterpret_cast<const sockaddr_dl*>(cur->ifa_addr);
      // LLADDR() returns char* on some BSDs; cast explicitly to avoid
      // const-qualification issues with caddr_t.
      const uint8_t* lladdr =
          reinterpret_cast<const uint8_t*>(LLADDR(addr_dl));
      memcpy(&interface->hardware_address[0], lladdr,
             sizeof(interface->hardware_address));
    } else if (cur->ifa_addr->sa_family == AF_INET6) {
      struct in6_ifreq ifr = {};
      strncpy(ifr.ifr_name, cur->ifa_name, sizeof(ifr.ifr_name) - 1);
      memcpy(&ifr.ifr_ifru.ifru_addr, cur->ifa_addr,
             cur->ifa_addr->sa_len);
      // On BSD, SIOCGIFAFLAG_IN6 fills ifru_flags6 (not ifru_flags as on macOS).
      if (ioctl(ioctl_socket.get(), SIOCGIFAFLAG_IN6, &ifr) != 0 ||
          ifr.ifr_ifru.ifru_flags6 & IN6_IFF_DEPRECATED) {
        continue;
      }

      auto* const addr_in6 =
          reinterpret_cast<const sockaddr_in6*>(cur->ifa_addr);
      uint8_t tmp[sizeof(addr_in6->sin6_addr.s6_addr)];
      memcpy(tmp, &(addr_in6->sin6_addr.s6_addr), sizeof(tmp));
      const IPAddress ip(IPAddress::Version::kV6, tmp);
      memset(tmp, 0, sizeof(tmp));
      if (cur->ifa_netmask && cur->ifa_netmask->sa_family == AF_INET6) {
        memcpy(tmp,
               &(reinterpret_cast<const sockaddr_in6*>(cur->ifa_netmask)
                     ->sin6_addr.s6_addr),
               sizeof(tmp));
      }
      interface->addresses.emplace_back(ip, ToPrefixLength(tmp));
    } else if (cur->ifa_addr->sa_family == AF_INET) {
      auto* const addr_in =
          reinterpret_cast<const sockaddr_in*>(cur->ifa_addr);
      uint8_t tmp[sizeof(addr_in->sin_addr.s_addr)];
      memcpy(tmp, &(addr_in->sin_addr.s_addr), sizeof(tmp));
      IPAddress ip(IPAddress::Version::kV4, tmp);
      memset(tmp, 0, sizeof(tmp));
      if (cur->ifa_netmask && cur->ifa_netmask->sa_family == AF_INET) {
        memcpy(tmp,
               &(reinterpret_cast<const sockaddr_in*>(cur->ifa_netmask)
                     ->sin_addr.s_addr),
               sizeof(tmp));
      }
      interface->addresses.emplace_back(ip, ToPrefixLength(tmp));
    }
  }

  freeifaddrs(interfaces);
  return results;
}

}  // namespace openscreen
