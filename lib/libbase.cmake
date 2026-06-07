#
# Copyright © 2022 Github Lzhiyong
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Common srcs (Android.bp: libbase_defaults). cmsg.cpp is excluded on windows
# (see below), so it lives in the per-OS block.
add_library(libbase STATIC
    ${SRC}/libbase/chrono_utils.cpp
    ${SRC}/libbase/file.cpp
    ${SRC}/libbase/hex.cpp
    ${SRC}/libbase/logging.cpp
    ${SRC}/libbase/mapped_file.cpp
    ${SRC}/libbase/parsebool.cpp
    ${SRC}/libbase/parsenetaddress.cpp
    ${SRC}/libbase/posix_strerror_r.cpp
    ${SRC}/libbase/process.cpp
    ${SRC}/libbase/properties.cpp
    ${SRC}/libbase/result.cpp
    ${SRC}/libbase/stringprintf.cpp
    ${SRC}/libbase/strings.cpp
    ${SRC}/libbase/threads.cpp
    ${SRC}/libbase/test_utils.cpp
    )

# Per-OS srcs (Android.bp: libbase_defaults target.{linux,darwin,windows}).
if(PLATFORM_WINDOWS)
    target_sources(libbase PRIVATE
        ${SRC}/libbase/errors_windows.cpp
        ${SRC}/libbase/utf8.cpp
        )
    # libbase_cflags_defaults target.windows
    target_compile_definitions(libbase PRIVATE -D_POSIX_THREAD_SAFE_FUNCTIONS)
else()
    # target.linux (android + host Linux) and target.darwin both add errors_unix;
    # cmsg.cpp is built everywhere except windows.
    target_sources(libbase PRIVATE
        ${SRC}/libbase/cmsg.cpp
        ${SRC}/libbase/errors_unix.cpp
        )
endif()

target_include_directories(libbase PRIVATE
    ${SRC}/libbase/include
    ${SRC}/core/include
    ${SRC}/fmtlib/include 
    ${SRC}/logging/liblog/include
    )
