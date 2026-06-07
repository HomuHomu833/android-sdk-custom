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

# libcutils = AOSP libcutils + libcutils_sockets merged. Per-OS source selection
# mirrors core/libcutils/Android.bp target.{linux,host,not_windows,android,windows}.
# faked_functions.cpp is our addition: cacheflush everywhere + the host property
# fakes (host has no Android property system).
add_library(libcutils STATIC
    # libcutils common srcs
    ${SRC}/core/libcutils/config_utils.cpp
    ${SRC}/core/libcutils/iosched_policy.cpp
    ${SRC}/core/libcutils/load_file.cpp
    ${SRC}/core/libcutils/native_handle.cpp
    ${SRC}/core/libcutils/properties.cpp
    ${SRC}/core/libcutils/record_stream.cpp
    ${SRC}/core/libcutils/strlcpy.c
    # libcutils_sockets common
    ${SRC}/core/libcutils/sockets.cpp
    ${SRC}/faked_functions.cpp
    )

# target.linux (android + host Linux)
if(PLATFORM_LINUX_KERNEL)
    target_sources(libcutils PRIVATE
        ${SRC}/core/libcutils/canned_fs_config.cpp
        ${SRC}/core/libcutils/fs_config.cpp
        )
endif()

# target.not_windows (host non-windows + android) -- incl. the unix sockets
if(PLATFORM_NOT_WINDOWS)
    target_sources(libcutils PRIVATE
        ${SRC}/core/libcutils/fs.cpp
        ${SRC}/core/libcutils/hashmap.cpp
        ${SRC}/core/libcutils/multiuser.cpp
        ${SRC}/core/libcutils/str_parms.cpp
        ${SRC}/core/libcutils/socket_inaddr_any_server_unix.cpp
        ${SRC}/core/libcutils/socket_local_client_unix.cpp
        ${SRC}/core/libcutils/socket_local_server_unix.cpp
        ${SRC}/core/libcutils/socket_network_client_unix.cpp
        ${SRC}/core/libcutils/sockets_unix.cpp
        )
endif()

# target.host (everything but the android device): host stubs for atrace/ashmem
if(PLATFORM_HOST)
    target_sources(libcutils PRIVATE
        ${SRC}/core/libcutils/trace-host.cpp
        ${SRC}/core/libcutils/ashmem-host.cpp
        )
endif()

# target.android (bionic device): the real device implementations
if(PLATFORM_ANDROID)
    target_sources(libcutils PRIVATE
        ${SRC}/core/libcutils/android_get_control_file.cpp
        ${SRC}/core/libcutils/android_reboot.cpp
        ${SRC}/core/libcutils/ashmem-dev.cpp
        ${SRC}/core/libcutils/klog.cpp
        ${SRC}/core/libcutils/partition_utils.cpp
        ${SRC}/core/libcutils/qtaguid.cpp
        ${SRC}/core/libcutils/trace-dev.cpp
        ${SRC}/core/libcutils/uevent.cpp
        )
endif()

# target.windows
if(PLATFORM_WINDOWS)
    target_sources(libcutils PRIVATE
        ${SRC}/core/libcutils/socket_inaddr_any_server_windows.cpp
        ${SRC}/core/libcutils/socket_network_client_windows.cpp
        ${SRC}/core/libcutils/sockets_windows.cpp
        )
    target_link_libraries(libcutils PRIVATE ws2_32)
endif()

target_compile_definitions(libcutils PRIVATE 
    -D_GNU_SOURCE
    )

set_source_files_properties(${SRC}/core/libcutils/strlcpy.c PROPERTIES
    COMPILE_DEFINITIONS "ANDROID_SDK_STRL_COMPAT_IMPLEMENTATION"
    )

target_include_directories(libcutils PRIVATE
    ${SRC}/core/libutils/include
    ${SRC}/core/libcutils/include
    ${SRC}/logging/liblog/include 
    ${SRC}/libbase/include
    ${SRC}/../include
    )
    
