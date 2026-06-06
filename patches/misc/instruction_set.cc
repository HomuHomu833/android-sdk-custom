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

#include "instruction_set.h"

#include "android-base/logging.h"
#include "android-base/properties.h"
#include "android-base/stringprintf.h"
#include "base/bit_utils.h"
#include "base/globals.h"

namespace art {

void InstructionSetAbort(InstructionSet isa) {
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
    case InstructionSet::kNone:
      LOG(FATAL) << "Unsupported instruction set " << isa;
      UNREACHABLE();
  }
  LOG(FATAL) << "Unknown ISA " << isa;
  UNREACHABLE();
}

const char* GetInstructionSetString(InstructionSet isa) {
  switch (isa) {
    case InstructionSet::kArm:
    case InstructionSet::kThumb2:
      return "arm";
    case InstructionSet::kArm64:
      return "arm64";
    case InstructionSet::kRiscv64:
      return "riscv64";
    case InstructionSet::kX86:
      return "x86";
    case InstructionSet::kX86_64:
      return "x86_64";
    case InstructionSet::kLoongArch64:
      return "loong64";
    case InstructionSet::kPowerPC:
      return "ppc64le";
    case InstructionSet::kS390X:
      return "s390x";
    case InstructionSet::kHexagon:
      return "hexagon";
    case InstructionSet::kNone:
      return "none";
  }
  LOG(FATAL) << "Unknown ISA " << isa;
  UNREACHABLE();
}

InstructionSet GetInstructionSetFromString(const char* isa_str) {
  CHECK(isa_str != nullptr);

  if (strcmp("arm", isa_str) == 0) {
    return InstructionSet::kArm;
  } else if (strcmp("arm64", isa_str) == 0) {
    return InstructionSet::kArm64;
  } else if (strcmp("riscv64", isa_str) == 0) {
    return InstructionSet::kRiscv64;
  } else if (strcmp("x86", isa_str) == 0) {
    return InstructionSet::kX86;
  } else if (strcmp("x86_64", isa_str) == 0) {
    return InstructionSet::kX86_64;
  } else if (strcmp("loong64", isa_str) == 0) {
    return InstructionSet::kLoongArch64;
  } else if (strcmp("ppc64le", isa_str) == 0) {
    return InstructionSet::kPowerPC;
  } else if (strcmp("s390x", isa_str) == 0) {
    return InstructionSet::kS390X;
  } else if (strcmp("hexagon", isa_str) == 0) {
    return InstructionSet::kHexagon;
  }

  return InstructionSet::kNone;
}

std::vector<InstructionSet> GetSupportedInstructionSets(std::string* error_msg) {
  std::string zygote_kinds = android::base::GetProperty("ro.zygote", {});
  if (zygote_kinds.empty()) {
    *error_msg = "Unable to get Zygote kinds";
    return {};
  }

  switch (kRuntimeISA) {
    case InstructionSet::kArm:
    case InstructionSet::kArm64:
      if (zygote_kinds == "zygote64_32" || zygote_kinds == "zygote32_64") {
        return {InstructionSet::kArm64, InstructionSet::kArm};
      } else if (zygote_kinds == "zygote64") {
        return {InstructionSet::kArm64};
      } else if (zygote_kinds == "zygote32") {
        return {InstructionSet::kArm};
      } else {
        *error_msg = android::base::StringPrintf("Unknown Zygote kinds '%s'", zygote_kinds.c_str());
        return {};
      }
    case InstructionSet::kRiscv64:
      return {InstructionSet::kRiscv64};
    case InstructionSet::kX86:
    case InstructionSet::kX86_64:
      if (zygote_kinds == "zygote64_32" || zygote_kinds == "zygote32_64") {
        return {InstructionSet::kX86_64, InstructionSet::kX86};
      } else if (zygote_kinds == "zygote64") {
        return {InstructionSet::kX86_64};
      } else if (zygote_kinds == "zygote32") {
        return {InstructionSet::kX86};
      } else {
        *error_msg = android::base::StringPrintf("Unknown Zygote kinds '%s'", zygote_kinds.c_str());
        return {};
      }
    case InstructionSet::kLoongArch64:
      return {InstructionSet::kLoongArch64};
    case InstructionSet::kPowerPC:
      return {InstructionSet::kPowerPC};
    case InstructionSet::kS390X:
      return {InstructionSet::kS390X};
    case InstructionSet::kHexagon:
      return {InstructionSet::kHexagon};
    default:
      *error_msg = android::base::StringPrintf("Unknown runtime ISA '%s'",
                                               GetInstructionSetString(kRuntimeISA));
      return {};
  }
}

namespace instruction_set_details {

#ifndef ART_FRAME_SIZE_LIMIT
#define ART_FRAME_SIZE_LIMIT 10000
#endif

// TODO: Should we require an extra page (RoundUp(SIZE) + gPageSize)?
static_assert(ART_FRAME_SIZE_LIMIT < kArmStackOverflowReservedBytes, "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kArm64StackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kRiscv64StackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kX86StackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kX86_64StackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kLoongArch64StackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kPowerPCStackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kS390XStackOverflowReservedBytes,
              "Frame size limit too large");
static_assert(ART_FRAME_SIZE_LIMIT < kHexagonStackOverflowReservedBytes,
              "Frame size limit too large");

NO_RETURN void GetStackOverflowReservedBytesFailure(const char* error_msg) {
  LOG(FATAL) << error_msg;
  UNREACHABLE();
}

}  // namespace instruction_set_details

}  // namespace art
