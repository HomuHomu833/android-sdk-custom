# Android SDK Custom

**Android SDK Custom** is a custom-built Android SDK that replaces the default binaries with rebuilt ones.

It integrates alternative libc implementations like **musl** (via **[Zig](https://ziglang.org/)**), **Bionic** (from the official Android NDK), **[llvm-mingw](https://github.com/mstorsjo/llvm-mingw)** and the macOS SDK (via **[osxcross](https://github.com/tpoechtrager/osxcross)**) to provide a more flexible and portable build environment.

This project is inspired by [lzhiyong's Android SDK Tools](https://github.com/lzhiyong/android-sdk-tools).

---

## 🚀 Features

- Custom-built binaries, sourced from Google's Android SDK repositories.
- Built using various toolchain's libc for improved portability and consistency.

---

## 🧭 Architecture & Platform Support

### 🔹 Zig-based Environment

**Platforms**
- Linux
- Android
- NetBSD
- FreeBSD
- OpenBSD

**Architectures**
- **X86 Family**: `x86`, `x86_64`, `x32`
- **ARM Family**: `arm`, `armeb`, `aarch64`, `aarch64_be`
- **RISC-V**: `riscv32`, `riscv64`
- **PowerPC**: `powerpc`, `powerpc64`, `powerpc64le`
- **MIPS**: `mips`, `mipsel`, `mips64`, `mips64el`
- **Thumb**: `thumb`, `thumbeb`
- **Other**: `loongarch64`, `s390x`, `hexagon`

---

### 🔹 Native Environment

**Platforms**
- Windows
- macOS
- Android

**Architectures**
- `x86`, `x86_64`
- `aarch64`
- `armv7` *(Android and Windows only)*
- `arm64ec` *(Windows-only)*
- `arm64e`, `x86_64h` *(macOS-only)*

---

## 🧰 Usage

This custom SDK works as a **drop-in replacement** for the standard Android SDK.<br>
Simply extract the archive and use it in your build setup just as you would with the official version.

---

## 🏗️ How It's Built

There are no hand-written build files. Each build converts AOSP's own `Android.bp` files to CMake, so any release can be built, whether an `android-*` tag or any `platform-tools-*` tag:

1. **`scripts/fetch-source.sh`** reads the AOSP manifest of `$TAG` and clones the projects from [`repos.json`](repos.json) that the release has. Projects move between releases, for example adb moved from `system/core` to `packages/modules/adb`.
2. **`scripts/patch-source.sh`** applies the source fixups the non-Soong toolchains need (musl, llvm-mingw, osxcross, the BSDs, the NDK below API 29). It is best-effort: a fixup a release doesn't need is reported and skipped.
3. **`builder`** evaluates every `Android.bp` the way Soong does for one OS/arch (defaults, `target`/`arch` properties, `select()`, Soong config variables, genrules, protos, yacc/lex). It then writes a CMake project for the SDK tools and everything they depend on. [`builder/overlay/*.bp`](builder/overlay) holds, in Blueprint syntax, everything this repo does differently from Soong: the tool list, the global flags, the libusb USB backends for Windows/BSD, the BSD sources, and stand-ins for modules outside the fetched set.
4. **`scripts/build.sh`** builds a host `protoc` from the same protobuf sources, then configures and builds the generated project with the target's cross toolchain.
5. **`scripts/make-sdk.sh`** takes Google's official platform-tools of the revision the sources declare (`development/sdk/plat_tools_source.prop_template`) and the newest official build-tools of that major version, swaps in the rebuilt binaries by name, drops any official binary it has no rebuild of, and archives the result.

To see what gets built for a target without compiling anything:

```bash
python3 -m builder --platform linux --triple x86_64-linux-musl --out build/generated
```

---

## ⚖️ License

This project is licensed under the **MIT License**.<br>
See the **[LICENSE](LICENSE)** file for more details.

---

## 💬 Contributing
Feel free to open pull requests or issues if you have any contributions or feedback!
