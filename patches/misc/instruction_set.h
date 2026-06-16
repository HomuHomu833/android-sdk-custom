/*
 * Copyright (C) 2011 The Android Open Source Project
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

#ifndef ART_LIBARTBASE_ARCH_INSTRUCTION_SET_H_
#define ART_LIBARTBASE_ARCH_INSTRUCTION_SET_H_

#include <iosfwd>
#include <string>
#include <vector>

#include "base/macros.h"
#include "base/pointer_size.h"

namespace art {

enum class InstructionSet {
  kNone,
  kArm,
  kArm64,
  kThumb2,
  kRiscv64,
  kX86,
  kX86_64,
  kLoongArch64,
  kPowerPC,
  kS390X,
  kHexagon,
  kMips,
  kMips64,
  kLast = kMips64
};
std::ostream& operator<<(std::ostream& os, InstructionSet rhs);

#if defined(__arm__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kArm;
#elif defined(__aarch64__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kArm64;
#elif defined (__riscv)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kRiscv64;
#elif defined(__i386__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kX86;
#elif defined(__x86_64__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kX86_64;
#elif defined(__loongarch__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kLoongArch64;
#elif defined(__powerpc__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kPowerPC;
#elif defined(__s390x__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kS390X;
#elif defined(__hexagon__)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kHexagon;
#elif defined(__mips__) && !defined(__mips64)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kMips;
#elif defined(__mips64)
static constexpr InstructionSet kRuntimeISA = InstructionSet::kMips64;
#else
static constexpr InstructionSet kRuntimeISA = InstructionSet::kNone;
#endif

// Architecture-specific pointer sizes
static constexpr PointerSize kArmPointerSize = PointerSize::k32;
static constexpr PointerSize kArm64PointerSize = PointerSize::k64;
static constexpr PointerSize kRiscv64PointerSize = PointerSize::k64;
static constexpr PointerSize kX86PointerSize = PointerSize::k32;
static constexpr PointerSize kX86_64PointerSize = PointerSize::k64;
static constexpr PointerSize kLoongArch64PointerSize = PointerSize::k64;
static constexpr PointerSize kPowerPCPointerSize = PointerSize::k64;
static constexpr PointerSize kS390XPointerSize = PointerSize::k64;
static constexpr PointerSize kHexagonPointerSize = PointerSize::k32;
static constexpr PointerSize kMipsPointerSize = PointerSize::k32;
static constexpr PointerSize kMips64PointerSize = PointerSize::k64;

// ARM64 default SVE vector length.
static constexpr size_t kArm64DefaultSVEVectorLength = 256;

// Code alignment (used for the first instruction of a subroutine, such as an entrypoint).
// This is the recommended alignment for maximum performance.
// ARM processors require code to be 4-byte aligned, but ARM ELF requires 8.
static constexpr size_t kArmCodeAlignment = 8;
static constexpr size_t kArm64CodeAlignment = 16;
static constexpr size_t kRiscv64CodeAlignment = 16;
static constexpr size_t kX86CodeAlignment = 16;
static constexpr size_t kLoongArch64CodeAlignment = 16;
static constexpr size_t kPowerPCCodeAlignment = 16;
static constexpr size_t kS390XCodeAlignment = 16;
static constexpr size_t kHexagonCodeAlignment = 16;
static constexpr size_t kMipsCodeAlignment = 4;
static constexpr size_t kMips64CodeAlignment = 4;

// Instruction alignment (every instruction must be aligned at this boundary). This differs from
// code alignment, which applies only to the first instruction of a subroutine.
// Android requires the RISC-V compressed instruction extension, and that allows
// *all* instructions (not just compressed ones) to be 2-byte aligned rather
// than the usual 4-byte alignment requirement.
static constexpr size_t kThumb2InstructionAlignment = 2;
static constexpr size_t kArm64InstructionAlignment = 4;
static constexpr size_t kRiscv64InstructionAlignment = 2;
static constexpr size_t kX86InstructionAlignment = 1;
static constexpr size_t kX86_64InstructionAlignment = 1;
static constexpr size_t kLoongArch64InstructionAlignment = 4;
static constexpr size_t kPowerPCInstructionAlignment = 4;
static constexpr size_t kS390XInstructionAlignment = 2;
static constexpr size_t kHexagonInstructionAlignment = 4;
static constexpr size_t kMipsInstructionAlignment = 4;
static constexpr size_t kMips64InstructionAlignment = 4;

const char* GetInstructionSetString(InstructionSet isa);

// Note: Returns kNone when the string cannot be parsed to a known value.
InstructionSet GetInstructionSetFromString(const char* instruction_set);

// Fatal logging out of line to keep the header clean of logging.h.
NO_RETURN void InstructionSetAbort(InstructionSet isa);

constexpr PointerSize GetInstructionSetPointerSize(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
      // Fall-through.
    case InstructionSet::kThumb2:
      return kArmPointerSize;
    case InstructionSet::kArm64:
      return kArm64PointerSize;
    case InstructionSet::kRiscv64:
      return kRiscv64PointerSize;
    case InstructionSet::kX86:
      return kX86PointerSize;
    case InstructionSet::kX86_64:
      return kX86_64PointerSize;
    case InstructionSet::kLoongArch64:
      return kLoongArch64PointerSize;
    case InstructionSet::kPowerPC:
      return kPowerPCPointerSize;
    case InstructionSet::kS390X:
      return kS390XPointerSize;
    case InstructionSet::kHexagon:
      return kHexagonPointerSize;
    case InstructionSet::kMips:
      return kMipsPointerSize;
    case InstructionSet::kMips64:
      return kMips64PointerSize;

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

constexpr bool IsValidInstructionSet(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
    case InstructionSet::kThumb2:
    case InstructionSet::kArm64:
    case InstructionSet::kRiscv64:
    case InstructionSet::kX86:
    case InstructionSet::kX86_64:
    case InstructionSet::kLoongArch64:
    case InstructionSet::kPowerPC:
    case InstructionSet::kS390X:
    case InstructionSet::kHexagon:
    case InstructionSet::kMips:
    case InstructionSet::kMips64:
      return true;

    case InstructionSet::kNone:
      return false;
  }
  return false;
}

constexpr size_t GetInstructionSetInstructionAlignment(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
      // Fall-through.
    case InstructionSet::kThumb2:
      return kThumb2InstructionAlignment;
    case InstructionSet::kArm64:
      return kArm64InstructionAlignment;
    case InstructionSet::kRiscv64:
      return kRiscv64InstructionAlignment;
    case InstructionSet::kX86:
      return kX86InstructionAlignment;
    case InstructionSet::kX86_64:
      return kX86_64InstructionAlignment;
    case InstructionSet::kLoongArch64:
      return kLoongArch64InstructionAlignment;
    case InstructionSet::kPowerPC:
      return kPowerPCInstructionAlignment;
    case InstructionSet::kS390X:
      return kS390XInstructionAlignment;
    case InstructionSet::kHexagon:
      return kHexagonInstructionAlignment;
    case InstructionSet::kMips:
      return kMipsInstructionAlignment;
    case InstructionSet::kMips64:
      return kMips64InstructionAlignment;

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

constexpr size_t GetInstructionSetCodeAlignment(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
      // Fall-through.
    case InstructionSet::kThumb2:
      return kArmCodeAlignment;
    case InstructionSet::kArm64:
      return kArm64CodeAlignment;
    case InstructionSet::kRiscv64:
      return kRiscv64CodeAlignment;
    case InstructionSet::kX86:
      // Fall-through.
    case InstructionSet::kX86_64:
      return kX86CodeAlignment;
    case InstructionSet::kLoongArch64:
      return kLoongArch64CodeAlignment;
    case InstructionSet::kPowerPC:
      return kPowerPCCodeAlignment;
    case InstructionSet::kS390X:
      return kS390XCodeAlignment;
    case InstructionSet::kHexagon:
      return kHexagonCodeAlignment;
    case InstructionSet::kMips:
      return kMipsCodeAlignment;
    case InstructionSet::kMips64:
      return kMips64CodeAlignment;

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

// Returns the difference between the code address and a usable PC.
// Mainly to cope with `kThumb2` where the lower bit must be set.
constexpr size_t GetInstructionSetEntryPointAdjustment(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
    case InstructionSet::kArm64:
    case InstructionSet::kRiscv64:
    case InstructionSet::kX86:
    case InstructionSet::kX86_64:
    case InstructionSet::kLoongArch64:
    case InstructionSet::kPowerPC:
    case InstructionSet::kS390X:
    case InstructionSet::kHexagon:
    case InstructionSet::kMips:
    case InstructionSet::kMips64:
      return 0;
    case InstructionSet::kThumb2: {
      // +1 to set the low-order bit so a BLX will switch to Thumb mode
      return 1;
    }

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

constexpr bool Is64BitInstructionSet(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
    case InstructionSet::kThumb2:
    case InstructionSet::kX86:
    case InstructionSet::kHexagon:
    case InstructionSet::kMips:
      return false;

    case InstructionSet::kArm64:
    case InstructionSet::kRiscv64:
    case InstructionSet::kX86_64:
    case InstructionSet::kLoongArch64:
    case InstructionSet::kPowerPC:
    case InstructionSet::kS390X:
    case InstructionSet::kMips64:
      return true;

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

constexpr PointerSize InstructionSetPointerSize(InstructionSet isa) {
  return Is64BitInstructionSet(isa) ? PointerSize::k64 : PointerSize::k32;
}

constexpr size_t GetBytesPerGprSpillLocation(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
      // Fall-through.
    case InstructionSet::kThumb2:
      return 4;
    case InstructionSet::kArm64:
      return 8;
    case InstructionSet::kRiscv64:
      return 8;
    case InstructionSet::kX86:
      return 4;
    case InstructionSet::kX86_64:
      return 8;
    case InstructionSet::kHexagon:
      return 4;
    case InstructionSet::kLoongArch64:
      return 8;
    case InstructionSet::kPowerPC:
      return 8;
    case InstructionSet::kS390X:
      return 8;
    case InstructionSet::kMips:
      return 4;
    case InstructionSet::kMips64:
      return 8;

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

constexpr size_t GetBytesPerFprSpillLocation(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
      // Fall-through.
    case InstructionSet::kThumb2:
      return 4;
    case InstructionSet::kArm64:
      return 8;
    case InstructionSet::kRiscv64:
      return 8;
    case InstructionSet::kX86:
      return 8;
    case InstructionSet::kX86_64:
      return 8;
    case InstructionSet::kHexagon:
      return 8;
    case InstructionSet::kLoongArch64:
      return 8;
    case InstructionSet::kPowerPC:
      return 8;
    case InstructionSet::kS390X:
      return 8;
    case InstructionSet::kMips:
      return 8;
    case InstructionSet::kMips64:
      return 8;

    case InstructionSet::kNone:
      break;
  }
  InstructionSetAbort(isa);
}

// Returns the instruction sets supported by the device, or an empty list on failure.
std::vector<InstructionSet> GetSupportedInstructionSets(std::string* error_msg);

namespace instruction_set_details {

#ifndef ART_STACK_OVERFLOW_GAP_arm
#define ART_STACK_OVERFLOW_GAP_arm 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_arm64
#define ART_STACK_OVERFLOW_GAP_arm64 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_riscv64
#define ART_STACK_OVERFLOW_GAP_riscv64 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_loongarch64
#define ART_STACK_OVERFLOW_GAP_loongarch64 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_x86
#define ART_STACK_OVERFLOW_GAP_x86 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_x86_64
#define ART_STACK_OVERFLOW_GAP_x86_64 20480
#endif
#ifndef ART_STACK_OVERFLOW_GAP_powerpc
#define ART_STACK_OVERFLOW_GAP_powerpc 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_s390x
#define ART_STACK_OVERFLOW_GAP_s390x 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_hexagon
#define ART_STACK_OVERFLOW_GAP_hexagon 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_mips
#define ART_STACK_OVERFLOW_GAP_mips 16384
#endif
#ifndef ART_STACK_OVERFLOW_GAP_mips64
#define ART_STACK_OVERFLOW_GAP_mips64 16384
#endif

#if !defined(ART_STACK_OVERFLOW_GAP_arm) || !defined(ART_STACK_OVERFLOW_GAP_arm64) || \
    !defined(ART_STACK_OVERFLOW_GAP_riscv64) || !defined(ART_STACK_OVERFLOW_GAP_loongarch64) || \
    !defined(ART_STACK_OVERFLOW_GAP_x86) || !defined(ART_STACK_OVERFLOW_GAP_x86_64) || \
    !defined(ART_STACK_OVERFLOW_GAP_powerpc) || !defined(ART_STACK_OVERFLOW_GAP_s390x) || \
    !defined(ART_STACK_OVERFLOW_GAP_hexagon) || !defined(ART_STACK_OVERFLOW_GAP_mips) || \
    !defined(ART_STACK_OVERFLOW_GAP_mips64)
#error "Missing defines for stack overflow gap"
#endif

static constexpr size_t kArmStackOverflowReservedBytes     = ART_STACK_OVERFLOW_GAP_arm;
static constexpr size_t kArm64StackOverflowReservedBytes   = ART_STACK_OVERFLOW_GAP_arm64;
static constexpr size_t kRiscv64StackOverflowReservedBytes = ART_STACK_OVERFLOW_GAP_riscv64;
static constexpr size_t kX86StackOverflowReservedBytes     = ART_STACK_OVERFLOW_GAP_x86;
static constexpr size_t kX86_64StackOverflowReservedBytes  = ART_STACK_OVERFLOW_GAP_x86_64;
static constexpr size_t kLoongArch64StackOverflowReservedBytes = ART_STACK_OVERFLOW_GAP_loongarch64;
static constexpr size_t kPowerPCStackOverflowReservedBytes = ART_STACK_OVERFLOW_GAP_powerpc;
static constexpr size_t kS390XStackOverflowReservedBytes = ART_STACK_OVERFLOW_GAP_s390x;
static constexpr size_t kHexagonStackOverflowReservedBytes = ART_STACK_OVERFLOW_GAP_hexagon;
static constexpr size_t kMipsStackOverflowReservedBytes    = ART_STACK_OVERFLOW_GAP_mips;
static constexpr size_t kMips64StackOverflowReservedBytes  = ART_STACK_OVERFLOW_GAP_mips64;

NO_RETURN void GetStackOverflowReservedBytesFailure(const char* error_msg);

}  // namespace instruction_set_details

ALWAYS_INLINE
constexpr size_t GetStackOverflowReservedBytes(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:      // Intentional fall-through.
    case InstructionSet::kThumb2:
      return instruction_set_details::kArmStackOverflowReservedBytes;

    case InstructionSet::kArm64:
      return instruction_set_details::kArm64StackOverflowReservedBytes;

    case InstructionSet::kRiscv64:
      return instruction_set_details::kRiscv64StackOverflowReservedBytes;

    case InstructionSet::kX86:
      return instruction_set_details::kX86StackOverflowReservedBytes;

    case InstructionSet::kX86_64:
      return instruction_set_details::kX86_64StackOverflowReservedBytes;

    case InstructionSet::kLoongArch64:
      return instruction_set_details::kLoongArch64StackOverflowReservedBytes;

    case InstructionSet::kPowerPC:
      return instruction_set_details::kPowerPCStackOverflowReservedBytes;

    case InstructionSet::kS390X:
      return instruction_set_details::kS390XStackOverflowReservedBytes;
    case InstructionSet::kHexagon:
      return instruction_set_details::kHexagonStackOverflowReservedBytes;

    case InstructionSet::kMips:
      return instruction_set_details::kMipsStackOverflowReservedBytes;

    case InstructionSet::kMips64:
      return instruction_set_details::kMips64StackOverflowReservedBytes;

    case InstructionSet::kNone:
      instruction_set_details::GetStackOverflowReservedBytesFailure(
          "kNone has no stack overflow size");
  }
  instruction_set_details::GetStackOverflowReservedBytesFailure("Unknown instruction set");
}

// The following definitions create return types for two word-sized entities that will be passed
// in registers so that memory operations for the interface trampolines can be avoided. The entities
// are the resolved method and the pointer to the code to be invoked.
//
// On x86 and ARM32, this is given for a *scalar* 64bit value. The definition thus *must* be
// uint64_t or long long int.
//
// On x86_64 and ARM64, structs are decomposed for allocation, so we can create a structs of
// two size_t-sized values.
//
// We need two operations:
//
// 1) A flag value that signals failure. The assembly stubs expect the lower part to be "0".
//    GetTwoWordFailureValue() will return a value that has lower part == 0.
//
// 2) A value that combines two word-sized values.
//    GetTwoWordSuccessValue() constructs this.
//
// IMPORTANT: If you use this to transfer object pointers, it is your responsibility to ensure
//            that the object does not move or the value is updated. Simple use of this is NOT SAFE
//            when the garbage collector can move objects concurrently. Ensure that required locks
//            are held when using!

#if defined(__i386__) || defined(__arm__) || (defined(__mips__) && !defined(__mips64)) || defined(__hexagon__)
using TwoWordReturn = uint64_t;

// Encodes method_ptr==nullptr and code_ptr==nullptr
static inline constexpr TwoWordReturn GetTwoWordFailureValue() {
  return 0;
}

// Use the lower 32b for the method pointer and the upper 32b for the code pointer.
static inline constexpr TwoWordReturn GetTwoWordSuccessValue(uintptr_t hi, uintptr_t lo) {
  static_assert(sizeof(uint32_t) == sizeof(uintptr_t), "Unexpected size difference");
  uint32_t lo32 = lo;
  uint64_t hi64 = static_cast<uint64_t>(hi);
  return ((hi64 << 32) | lo32);
}

#elif defined(__x86_64__) || defined(__aarch64__) || defined(__riscv) || defined(__loongarch__) || defined(__powerpc__) || defined(__s390x__) || defined(__mips64)

// Note: TwoWordReturn can't be constexpr for 64-bit targets. We'd need a constexpr constructor,
//       which would violate C-linkage in the entrypoint functions.

struct TwoWordReturn {
  uintptr_t lo;
  uintptr_t hi;
};

// Encodes method_ptr==nullptr. Leaves random value in code pointer.
static inline TwoWordReturn GetTwoWordFailureValue() {
  TwoWordReturn ret;
  ret.lo = 0;
  return ret;
}

// Write values into their respective members.
static inline TwoWordReturn GetTwoWordSuccessValue(uintptr_t hi, uintptr_t lo) {
  TwoWordReturn ret;
  ret.lo = lo;
  ret.hi = hi;
  return ret;
}
#else
#error "Unsupported architecture"
#endif

}  // namespace art

#endif  // ART_LIBARTBASE_ARCH_INSTRUCTION_SET_H_
