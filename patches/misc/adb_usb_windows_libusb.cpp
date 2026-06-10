/*
 * Copyright (C) 2024 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Windows USB entry points for the libusb-only build.
//
// adb's native Windows backend (client/usb_windows.cpp) is built on the prebuilt
// AdbWinApi, shipped only as a 32-bit (i686) DLL, so it can't be linked into a
// 64-bit adb.exe. We build the libusb (WinUSB) backend instead -- the modern
// event-driven LibUsbConnection path (client/usb_libusb*.cpp), which does its own
// device I/O via LibUsbDevice and registers transports through
// register_libusb_transport().
//
// usb_windows.cpp also defined the global usb_init()/usb_cleanup() that
// client/main.cpp calls. With it gone, this file provides them for the libusb
// backend. (The BlockingConnection usb_read/usb_write/... entry points the native
// backends also defined are unused on the libusb path -- the legacy UsbConnection
// is excluded from this build, see patch-source.sh -- so they're intentionally
// absent rather than stubbed.)

#include "usb.h"

#include "adb_trace.h"
#include "client/usb_libusb_hotplug.h"
#include "transport.h"

// adb start-server calls this once to bring the USB stack up. On Windows the only
// backend is libusb, so start its hotplug/event machinery.
void usb_init() {
    libusb::usb_init();
}

// adb_server_cleanup() calls this on exit. Mirror usb_windows.cpp's behaviour:
// release the claimed WinUSB interfaces, otherwise re-claiming them on the next
// adb start-server is unreliable.
void usb_cleanup() {
    if (is_libusb_enabled()) {
        VLOG(USB) << "Windows libusb cleanup";
        close_usb_devices();
    }
}
