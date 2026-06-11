// BSD ADB USB entry points for the libusb-only build.
//
// The legacy BlockingConnection USB path (UsbConnection + usb_read/write/close/
// kick/reset/get_max_packet_size + register_usb_transport) is excluded from BSD
// builds via transport_usb.cpp and transport.cpp guards in patch-source.sh — the
// same approach used for Windows.  Only usb_init() and usb_cleanup() are needed
// to satisfy the references from client/main.cpp.
//
// USB hardware access is not supported in BSD cross-compilation builds; adb
// operates over TCP/IP connections.  usb_init() and usb_cleanup() are no-ops.

#include "client/usb.h"

void usb_init() {}
void usb_cleanup() {}
