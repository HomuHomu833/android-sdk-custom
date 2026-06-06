/*
 * Copyright (C) 2014 The Android Open Source Project
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

#include <gtest/gtest.h>

#include "base/pointer_size.h"

namespace art {

TEST(InstructionSetTest, GetInstructionSetFromString) {
  EXPECT_EQ(InstructionSet::kArm, GetInstructionSetFromString("arm"));
  EXPECT_EQ(InstructionSet::kArm64, GetInstructionSetFromString("arm64"));
  EXPECT_EQ(InstructionSet::kX86, GetInstructionSetFromString("x86"));
  EXPECT_EQ(InstructionSet::kX86_64, GetInstructionSetFromString("x86_64"));
  EXPECT_EQ(InstructionSet::kLoongArch64, GetInstructionSetFromString("loong64"));
  EXPECT_EQ(InstructionSet::kPowerPC, GetInstructionSetFromString("ppc64le"));
  EXPECT_EQ(InstructionSet::kS390X, GetInstructionSetFromString("s390x"));
  EXPECT_EQ(InstructionSet::kHexagon, GetInstructionSetFromString("hexagon"));
  EXPECT_EQ(InstructionSet::kNone, GetInstructionSetFromString("none"));
  EXPECT_EQ(InstructionSet::kNone, GetInstructionSetFromString("random-string"));
}

TEST(InstructionSetTest, GetInstructionSetString) {
  EXPECT_STREQ("arm", GetInstructionSetString(InstructionSet::kArm));
  EXPECT_STREQ("arm", GetInstructionSetString(InstructionSet::kThumb2));
  EXPECT_STREQ("arm64", GetInstructionSetString(InstructionSet::kArm64));
  EXPECT_STREQ("x86", GetInstructionSetString(InstructionSet::kX86));
  EXPECT_STREQ("x86_64", GetInstructionSetString(InstructionSet::kX86_64));
  EXPECT_STREQ("loong64", GetInstructionSetString(InstructionSet::kLoongArch64));
  EXPECT_STREQ("ppc64le", GetInstructionSetString(InstructionSet::kPowerPC));
  EXPECT_STREQ("s390x", GetInstructionSetString(InstructionSet::kS390X));
  EXPECT_STREQ("hexagon", GetInstructionSetString(InstructionSet::kHexagon));
  EXPECT_STREQ("none", GetInstructionSetString(InstructionSet::kNone));
}

TEST(InstructionSetTest, GetInstructionSetInstructionAlignment) {
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kThumb2),
            kThumb2InstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kArm64),
            kArm64InstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kX86),
            kX86InstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kX86_64),
            kX86_64InstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kLoongArch64),
            kLoongArch64InstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kPowerPC),
            kPowerPCInstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kS390X),
            kS390XInstructionAlignment);
  EXPECT_EQ(GetInstructionSetInstructionAlignment(InstructionSet::kHexagon),
            kHexagonInstructionAlignment);
}

TEST(InstructionSetTest, TestRoundTrip) {
  EXPECT_EQ(kRuntimeISA, GetInstructionSetFromString(GetInstructionSetString(kRuntimeISA)));
}

TEST(InstructionSetTest, PointerSize) {
  EXPECT_EQ(kRuntimePointerSize, GetInstructionSetPointerSize(kRuntimeISA));
}

}  // namespace art
