# termux-adb integration (bionic adb/fastboot)

Lets the bionic `adb`/`fastboot` run inside Termux without root: USB device FDs
are obtained from the `termux-usb` command (Termux:API) over a Unix socket
instead of reading `/dev/bus/usb` directly.

The shim is **always compiled into the bionic `adb`/`fastboot`** but is **off by
default** — the `termuxadb::` wrappers fall back to the normal libc/sysfs paths
unless the user sets `LIBUSB_TERMUX_IMPL=1` in the environment at runtime. So the
binaries behave exactly like stock for normal/rooted use, and non-rooted Termux
users opt in with:

```
LIBUSB_TERMUX_IMPL=1 adb devices
LIBUSB_TERMUX_IMPL=1 fastboot devices
```

Runtime also requires Termux + Termux:API (the `termux-usb` binary on `PATH`).

Sourced from https://github.com/nohajc/vendor-adb-patched (tag 35.0.2):
- `libtermuxadb/` — Rust staticlib exposing the `termuxadb_*` C shims (built by
  scripts/build.sh, linked by the adb/fastboot CMake files).
- `termux_adb.h` / `termux_fastboot.h` — C++ wrappers (namespace `termuxadb`)
  over those shims, applied to the adb/fastboot USB enumeration paths by
  scripts/patch-source.sh. Ported to the 36.x sources this repo builds, with
  every wrapper runtime-gated on `LIBUSB_TERMUX_IMPL` (`termuxadb::enabled()`).

Notes:
- adb's enumeration already walks `/dev/bus/usb`, so the wrappers are transparent
  when disabled. fastboot 36.x scans sysfs, so a separate `find_usb_device_termux`
  is dispatched only when enabled; the stock sysfs path is kept otherwise.
- `riscv64-linux-android` builds without the shim (Rust std target not bundled).
