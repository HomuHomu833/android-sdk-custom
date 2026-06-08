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
- **X86 Family**: `x86`, `x86_64`, `x32`
- **ARM Family**: `armhf`, `armeb`, `aarch64`, `aarch64_be`
- **RISC-V**: `riscv32`, `riscv64`
- **PowerPC**: `powerpc`, `powerpc64`, `powerpc64le`
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
- `armv7a` *(Android-only)*
- `arm64e`, `x86_64h` *(macOS-only)*

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
