// adb's USB entry points on the BSDs, where libusb is the only backend
// (patch-source.sh guards out the native one): usb_init() starts the libusb
// hotplug scanner, usb_cleanup() closes the open USB transports.

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
