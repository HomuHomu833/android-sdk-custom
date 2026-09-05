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
- Linux *(glibc and musl)*
- NetBSD
- FreeBSD
- OpenBSD

**Architectures**
- **X86 Family**: `x86`, `x86_64` *(plus the `x32` ABI on Linux)*
- **ARM Family**: `arm` *(soft- and hard-float)*, `armeb`, `aarch64`, `aarch64_be`
- **RISC-V**: `riscv32`, `riscv64`
- **PowerPC**: `powerpc`, `powerpc64`, `powerpc64le`
- **MIPS**: `mips`, `mipsel`, `mips64`, `mips64el`
- **Thumb**: `thumb`, `thumbeb` *(Linux-only)*
- **Other**: `loongarch64`, `s390x`, `hexagon` *(Linux-only)*

---

### 🔹 Native Environment

**Platforms**
- Windows *(via llvm-mingw)*
- macOS *(via osxcross)*
- Android *(via the official NDK)*

**Architectures**
- **Windows**: `x86`, `x86_64`, `aarch64`, `armv7`, `arm64ec`
- **macOS**: `x86_64`, `x86_64h`, `arm64`, `arm64e`
- **Android**: `x86`, `x86_64`, `aarch64`, `armv7a`

---

## 🧰 Usage

This custom SDK works as a **drop-in replacement** for the standard Android SDK.<br>
Simply extract the archive and use it in your build setup just as you would with the official version.

---

## ⚖️ License

This project is licensed under the **MIT License**.<br>
See the **[LICENSE](LICENSE)** file for more details.

---

## 💬 Contributing
Feel free to open pull requests or issues if you have any contributions or feedback!
