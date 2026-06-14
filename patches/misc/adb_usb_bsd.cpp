// BSD ADB USB entry points for the libusb build.
//
// BSD uses libusb as the only USB backend (no native BSD USB backend is
// compiled — the legacy BlockingConnection path is excluded via guards in
// patch-source.sh, same approach as Windows).
//
// usb_init() starts the libusb hotplug scanner; usb_cleanup() closes all open
// USB device transports.  These mirror the macOS / Linux libusb-enabled path.

#include "client/usb.h"
#include "client/usb_libusb_hotplug.h"
#include "transport.h"

void usb_init() {
    libusb::usb_init();
}

void usb_cleanup() {
    close_usb_devices();
}
