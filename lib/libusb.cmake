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

add_library(libusb STATIC
    ${SRC}/libusb/libusb/core.c
    ${SRC}/libusb/libusb/descriptor.c
    ${SRC}/libusb/libusb/hotplug.c
    ${SRC}/libusb/libusb/io.c
    ${SRC}/libusb/libusb/sync.c
    ${SRC}/libusb/libusb/strerror.c
    )

if(PLATFORM_DARWIN)
    target_sources(libusb PRIVATE
        ${SRC}/libusb/libusb/os/darwin_usb.c
        ${SRC}/libusb/libusb/os/events_posix.c
        ${SRC}/libusb/libusb/os/threads_posix.c
        )
elseif(PLATFORM_WINDOWS)
    target_sources(libusb PRIVATE
        ${SRC}/libusb/libusb/os/events_windows.c
        ${SRC}/libusb/libusb/os/threads_windows.c
        ${SRC}/libusb/libusb/os/windows_common.c
        ${SRC}/libusb/libusb/os/windows_usbdk.c
        ${SRC}/libusb/libusb/os/windows_winusb.c
        )
elseif(PLATFORM_BSD)
    target_sources(libusb PRIVATE
        ${SRC}/libusb/libusb/os/events_posix.c
        ${SRC}/libusb/libusb/os/threads_posix.c
        )
    if(CMAKE_SYSTEM_NAME STREQUAL "NetBSD")
        target_sources(libusb PRIVATE ${SRC}/libusb/libusb/os/netbsd_usb.c)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "OpenBSD")
        target_sources(libusb PRIVATE ${SRC}/libusb/libusb/os/openbsd_usb.c)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
       target_sources(libusb PRIVATE ${SRC}/libusb/libusb/os/freebsd_usb.c)
    else()
        target_sources(libusb PRIVATE ${SRC}/libusb/libusb/os/null_usb.c)
    endif()
else()
    target_sources(libusb PRIVATE
        ${SRC}/libusb/libusb/os/linux_usbfs.c
        ${SRC}/libusb/libusb/os/events_posix.c
        ${SRC}/libusb/libusb/os/threads_posix.c
        ${SRC}/libusb/libusb/os/linux_netlink.c
        )
endif()
if(PLATFORM_DARWIN)
    target_include_directories(libusb PRIVATE
        ${SRC}/libusb/libusb
        ${SRC}/libusb/libusb/os
        ${SRC}/libusb/darwin
        )
elseif(PLATFORM_WINDOWS)
    target_include_directories(libusb PRIVATE
        ${SRC}/libusb/libusb
        ${SRC}/libusb/libusb/os
        ${SRC}/libusb/windows
        )
elseif(PLATFORM_BSD)
    target_include_directories(libusb PRIVATE
        ${SRC}/libusb/libusb
        ${SRC}/libusb/libusb/os
        ${SRC}/libusb/darwin
        )
else()
    target_include_directories(libusb PRIVATE
        ${SRC}/libusb/libusb
        ${SRC}/libusb/libusb/os
        ${SRC}/libusb/linux
        )
endif()
target_compile_options(libusb PRIVATE
    -fvisibility=hidden
    -pthread
    -DANDROID_OS
    )
if(PLATFORM_BSD)
    target_compile_options(libusb PRIVATE -UHAVE_PTHREAD_THREADID_NP)
endif()
