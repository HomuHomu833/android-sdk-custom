# termux-adb integration (bionic only, opt-in via TERMUX_ADB=1)

Lets the bionic `adb`/`fastboot` run inside Termux without root: USB device
FDs are obtained from the `termux-usb` command (Termux:API) over a Unix socket
instead of reading `/dev/bus/usb` directly.

Sourced from https://github.com/nohajc/vendor-adb-patched (tag 35.0.2):
- `libtermuxadb/` — Rust staticlib exposing the `termuxadb_*` C shims.
- `termux_adb.h` / `termux_fastboot.h` — C++ wrappers (namespace `termuxadb`)
  over those shims, force-applied to the adb/fastboot USB enumeration paths by
  scripts/patch-source.sh. Ported to the 36.x sources this repo builds.

Runtime requires Termux + Termux:API (the `termux-usb` binary on PATH).
