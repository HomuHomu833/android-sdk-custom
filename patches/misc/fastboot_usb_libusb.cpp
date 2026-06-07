/*
 * libusb-based USB backend for fastboot.
 *
 * fastboot upstream ships native backends only (usb_linux.cpp / usb_osx.cpp /
 * usb_windows.cpp); the windows one needs the prebuilt AdbWinApi (shipped 32-bit
 * only). This backend implements the same usb.h interface over libusb (WinUSB on
 * Windows), so fastboot can be built for windows with no AdbWinApi dependency.
 *
 * Installed into src/core/fastboot/usb_libusb.cpp by scripts/patch-source.sh and
 * compiled in place of usb_windows.cpp for the windows target (see fastboot.cmake).
 */

#include "usb.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>

#include <libusb.h>

#include <android-base/logging.h>

namespace {

constexpr int kBulkChunk = 16384;

class LibusbTransport : public UsbTransport {
  public:
    LibusbTransport(libusb_context* ctx, libusb_device_handle* handle, int interface,
                    uint8_t ep_in, uint8_t ep_out, uint32_t timeout_ms)
        : ctx_(ctx),
          handle_(handle),
          interface_(interface),
          ep_in_(ep_in),
          ep_out_(ep_out),
          timeout_ms_(timeout_ms) {}

    ~LibusbTransport() override { Close(); }

    ssize_t Read(void* data, size_t len) override;
    ssize_t Write(const void* data, size_t len) override;
    int Close() override;
    int Reset() override;

  private:
    libusb_context* ctx_ = nullptr;
    libusb_device_handle* handle_ = nullptr;
    int interface_ = -1;
    uint8_t ep_in_ = 0;
    uint8_t ep_out_ = 0;
    uint32_t timeout_ms_ = 0;
};

ssize_t LibusbTransport::Write(const void* data, size_t len) {
    if (handle_ == nullptr) return -1;
    auto* buf = const_cast<unsigned char*>(static_cast<const unsigned char*>(data));
    size_t count = 0;
    while (count < len) {
        int chunk = static_cast<int>(std::min(len - count, static_cast<size_t>(kBulkChunk)));
        int transferred = 0;
        int rc = libusb_bulk_transfer(handle_, ep_out_, buf + count, chunk, &transferred,
                                      timeout_ms_);
        if (rc != 0) {
            LOG(ERROR) << "fastboot libusb bulk-out failed: " << libusb_error_name(rc);
            return -1;
        }
        count += static_cast<size_t>(transferred);
    }
    return static_cast<ssize_t>(count);
}

ssize_t LibusbTransport::Read(void* data, size_t len) {
    if (handle_ == nullptr) return -1;
    auto* buf = static_cast<unsigned char*>(data);
    int transferred = 0;
    int rc = libusb_bulk_transfer(handle_, ep_in_, buf, static_cast<int>(len), &transferred,
                                  timeout_ms_);
    if (rc != 0) {
        LOG(ERROR) << "fastboot libusb bulk-in failed: " << libusb_error_name(rc);
        return -1;
    }
    return static_cast<ssize_t>(transferred);
}

int LibusbTransport::Close() {
    if (handle_ != nullptr) {
        if (interface_ >= 0) libusb_release_interface(handle_, interface_);
        libusb_close(handle_);
        handle_ = nullptr;
    }
    if (ctx_ != nullptr) {
        libusb_exit(ctx_);
        ctx_ = nullptr;
    }
    return 0;
}

int LibusbTransport::Reset() {
    if (handle_ == nullptr) return -1;
    return libusb_reset_device(handle_) == 0 ? 0 : -1;
}

// Fill a usb_ifc_info for one interface and locate its bulk endpoints.
void fill_ifc_info(const libusb_device_descriptor& dd, const libusb_interface_descriptor& id,
                   uint8_t bus, uint8_t addr, usb_ifc_info* info, uint8_t* ep_in, uint8_t* ep_out) {
    memset(info, 0, sizeof(*info));
    info->dev_vendor = dd.idVendor;
    info->dev_product = dd.idProduct;
    info->dev_class = dd.bDeviceClass;
    info->dev_subclass = dd.bDeviceSubClass;
    info->dev_protocol = dd.bDeviceProtocol;
    info->ifc_class = id.bInterfaceClass;
    info->ifc_subclass = id.bInterfaceSubClass;
    info->ifc_protocol = id.bInterfaceProtocol;
    info->writable = 1;
    snprintf(info->device_path, sizeof(info->device_path), "usb:%u-%u", bus, addr);

    *ep_in = 0;
    *ep_out = 0;
    for (uint8_t e = 0; e < id.bNumEndpoints; ++e) {
        const libusb_endpoint_descriptor& ep = id.endpoint[e];
        if ((ep.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
        if (ep.bEndpointAddress & LIBUSB_ENDPOINT_IN) {
            *ep_in = ep.bEndpointAddress;
            info->has_bulk_in = 1;
        } else {
            *ep_out = ep.bEndpointAddress;
            info->has_bulk_out = 1;
        }
    }
}

}  // namespace

std::unique_ptr<UsbTransport> usb_open(ifc_match_func callback, uint32_t timeout_ms) {
    libusb_context* ctx = nullptr;
    if (libusb_init(&ctx) != 0) {
        LOG(ERROR) << "fastboot: libusb_init failed";
        return nullptr;
    }

    libusb_device** devs = nullptr;
    ssize_t n = libusb_get_device_list(ctx, &devs);
    std::unique_ptr<UsbTransport> result;

    for (ssize_t i = 0; i < n && !result; ++i) {
        libusb_device* dev = devs[i];

        libusb_device_descriptor dd;
        if (libusb_get_device_descriptor(dev, &dd) != 0) continue;

        libusb_config_descriptor* cfg = nullptr;
        if (libusb_get_active_config_descriptor(dev, &cfg) != 0) continue;

        const uint8_t bus = libusb_get_bus_number(dev);
        const uint8_t addr = libusb_get_device_address(dev);

        for (uint8_t ii = 0; ii < cfg->bNumInterfaces && !result; ++ii) {
            const libusb_interface& intf = cfg->interface[ii];
            for (int alt = 0; alt < intf.num_altsetting && !result; ++alt) {
                const libusb_interface_descriptor& id = intf.altsetting[alt];

                usb_ifc_info info;
                uint8_t ep_in = 0, ep_out = 0;
                fill_ifc_info(dd, id, bus, addr, &info, &ep_in, &ep_out);

                // Opening the device lets us read the serial and is also how we
                // filter to WinUSB-bound devices on windows.
                libusb_device_handle* handle = nullptr;
                if (libusb_open(dev, &handle) != 0) continue;

                if (dd.iSerialNumber != 0) {
                    libusb_get_string_descriptor_ascii(
                        handle, dd.iSerialNumber,
                        reinterpret_cast<unsigned char*>(info.serial_number),
                        sizeof(info.serial_number));
                }

                if (callback(&info) == 0 && info.has_bulk_in && info.has_bulk_out) {
                    libusb_set_auto_detach_kernel_driver(handle, 1);  // no-op on windows
                    if (libusb_claim_interface(handle, id.bInterfaceNumber) == 0) {
                        result = std::make_unique<LibusbTransport>(
                            ctx, handle, id.bInterfaceNumber, ep_in, ep_out, timeout_ms);
                        handle = nullptr;  // ownership moved into the transport
                    }
                }

                if (handle != nullptr) libusb_close(handle);
            }
        }
        libusb_free_config_descriptor(cfg);
    }

    libusb_free_device_list(devs, 1);
    if (!result) libusb_exit(ctx);  // the transport owns ctx on success
    return result;
}
