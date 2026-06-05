# Android SDK Custom

**Android SDK Custom** is a custom-built Android SDK that replaces the default binaries with musl-based ones built using **[Zig](https://ziglang.org/)**.

This project is inspired by [lzhiyong's Android SDK Tools](https://github.com/lzhiyong/android-sdk-tools).

---

## 🚀 Features

- Custom-built binaries, sourced from Google's Android SDK repositories.
- Built using Zig to provide musl-based toolchains for improved portability and consistency.

---

## 🧭 Architecture & Platform Support

### 🔹 Zig-based Environment

**Platforms**
- Linux
- Android

**Architectures**
- **X86 Family**: `x86`, `x86_64`
- **ARM Family**: `armhf`, `armeb`, `aarch64`, `aarch64_be`
- **RISC-V**: `riscv32`, `riscv64` 
- **Other**: `loongarch64`, `powerpc64le`, `s390x`

---

## 🧰 Usage

This custom SDK works as a **drop-in replacement** for the standard Android SDK.<br>
Simply extract the archive and use it in your build setup just as you would with the official version.

---

## 🏗️ Building

The build is driven by env-var-controlled shell scripts that run **identically in
CI and locally** inside a prebuilt Docker image (the same layout as the sibling
[`android-ndk-custom`](https://github.com/HomuHomu833/android-ndk-custom) and
[`llvm-custom`](https://github.com/HomuHomu833/llvm-custom) projects).

| Path | Role |
|------|------|
| `docker/Dockerfile` | Builder image — bakes the zig + zig-as-llvm toolchain. Scripts are bind-mounted at run time, so editing them needs no image rebuild. |
| `scripts/fetch-source.sh` | Clone the AOSP sources from `repos.json`, drop in the prebuilt `patches/misc/*` files, then run `patch-source.sh`. |
| `scripts/patch-source.sh` | The in-place source fixups (the `sed` wall that used to live inline in the workflow). |
| `scripts/build.sh` | Cross-build the host tools for one `TARGET` (native `protoc` + static zlib/bzip2 + the CMake project). |
| `scripts/make-sdk.sh` | Splice the built tools into Google's official SDK and archive `android-sdk-<target>.tar.xz`. |

### Build one target locally

The whole pipeline runs in a single container (the image carries a JRE for
`sdkmanager`), exactly as CI does:

```sh
docker build -t sdk-builder ./docker
docker run --rm -v "$PWD:/work" -w /work \
  -e PLATFORM=linux -e TARGET=x86_64-linux-musl -e TAG=android-16.0.0_r4 \
  sdk-builder bash -c 'scripts/fetch-source.sh && scripts/build.sh && scripts/make-sdk.sh'
# -> android-sdk-x86_64-linux-musl.tar.xz
```

`TARGET` accepts both musl (fully static) and gnu (dynamic libc, static
libstdc++/libgcc) triples — the same linux target set the sibling repos build;
see `.github/workflows/make_sdk_linux.yml`. `PLATFORM` is `linux` only for now;
the toolchain dispatch in `build.sh` is structured so `windows` (llvm-mingw),
`macos` (osxcross) and `bionic` (NDK clang) can be added the same way.

---

## ⚖️ License

This project is licensed under the **MIT License**.<br>
See the **[LICENSE](LICENSE)** file for more details.

---

## 💬 Contributing
Feel free to open pull requests or issues if you have any contributions or feedback!
