// BSD ADB USB entry points for the libusb build.
//
// BSD uses libusb as the only USB backend (no native BSD USB backend is
// compiled — the legacy BlockingConnection path is excluded via guards in
// patch-source.sh, same approach as Windows).
//
// usb_init() starts the libusb hotplug scanner; usb_cleanup() closes all open
// USB device transports.  These mirror the macOS / Linux libusb-enabled path.

#include "client/usb.h"
// Newer adb split the libusb backend; older releases declare
// libusb::usb_init() in client/usb.h and have no close_usb_devices().
#if __has_include("client/usb_libusb_hotplug.h")
#include "client/usb_libusb_hotplug.h"
#define SDK_ADB_HAS_CLOSE_USB_DEVICES 1
#endif
#include "transport.h"

void usb_init() {
    libusb::usb_init();
}

void usb_cleanup() {
#if defined(SDK_ADB_HAS_CLOSE_USB_DEVICES)
    close_usb_devices();
#endif
}
