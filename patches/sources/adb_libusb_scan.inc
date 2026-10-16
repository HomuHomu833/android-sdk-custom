// Spliced into older adb's client/usb_libusb.cpp (platform-tools 35.0.2 and
// earlier) by patch-source.sh. There usb_init() aborts when libusb has no
// hotplug, as on every BSD backend; instead scan the device list every two
// seconds and feed hotplug_callback(), as newer adb's in-house hotplug does.
static void sdk_scan_usb_devices() {
    std::thread([]() {
        adb_thread_setname("libusb scan");
        // Held references; a departed device is released one scan later, once
        // the hotplug thread has handled its LEFT event.
        std::vector<libusb_device*> known, released;
        while (true) {
            for (libusb_device* d : released) libusb_unref_device(d);
            released.clear();

            libusb_device** list;
            ssize_t n = libusb_get_device_list(nullptr, &list);
            if (n >= 0) {
                std::vector<libusb_device*> now(list, list + n);
                for (libusb_device* d : now) {
                    if (std::find(known.begin(), known.end(), d) == known.end()) {
                        known.push_back(libusb_ref_device(d));
                        hotplug_callback(nullptr, d, LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED, nullptr);
                    }
                }
                for (auto it = known.begin(); it != known.end();) {
                    if (std::find(now.begin(), now.end(), *it) == now.end()) {
                        hotplug_callback(nullptr, *it, LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT, nullptr);
                        released.push_back(*it);
                        it = known.erase(it);
                    } else {
                        ++it;
                    }
                }
                libusb_free_device_list(list, 1);
            }
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
    }).detach();
}

