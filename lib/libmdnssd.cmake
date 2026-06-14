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

add_library(libmdnssd STATIC
    ${SRC}/mdnsresponder/mDNSShared/dnssd_clientlib.c
    ${SRC}/mdnsresponder/mDNSShared/dnssd_clientstub.c
    ${SRC}/mdnsresponder/mDNSShared/dnssd_ipc.c
    )

if(PLATFORM_WINDOWS)
    target_sources(libmdnssd PRIVATE
        ${SRC}/mdnsresponder/mDNSWindows/DLL/dllmain.c
        )
endif()

target_include_directories(libmdnssd PRIVATE
    ${SRC}/mdnsresponder/mDNSShared
    )
target_compile_options(libmdnssd PRIVATE
    -fno-strict-aliasing
    -fwrapv
    )

target_compile_definitions(libmdnssd PRIVATE
    -D_GNU_SOURCE
    -DHAVE_IPV6
    -DNOT_HAVE_SA_LEN
    -DPLATFORM_NO_RLIMIT
    -DMDNS_USERNAME="mdnsr"
    -DMDNS_DEBUGMSGS=0
    )

if(PLATFORM_DARWIN)
    target_compile_definitions(libmdnssd PRIVATE
        -DTARGET_OS_MAC
        -DMDNS_UDS_SERVERPATH="/var/run/mDNSResponder"
        )
elseif(PLATFORM_WINDOWS)
    target_compile_definitions(libmdnssd PRIVATE
        -DTARGET_OS_WINDOWS -DWIN32 -D_WIN32_LEAN_AND_MEAN -DUSE_TCP_LOOPBACK
        -D_WINDOWS -D_USERDLL -D_SSIZE_T -DNOT_HAVE_SA_LENGTH
        -D_CRT_SECURE_NO_DEPRECATE -D_CRT_SECURE_CPP_OVERLOAD_STANDARD_NAMES=1
        -DMDNS_UDS_SERVERPATH="/dev/socket/mdnsd"
        )
    target_compile_options(libmdnssd PRIVATE "-include" "winsock2.h")
elseif(PLATFORM_BSD)
    target_compile_definitions(libmdnssd PRIVATE
        -DTARGET_OS_LINUX
        -DMDNS_UDS_SERVERPATH="/var/run/mdnsd"
        )
else()
    target_compile_definitions(libmdnssd PRIVATE
        -DTARGET_OS_LINUX -DHAVE_LINUX -DUSES_NETLINK
        -DMDNS_UDS_SERVERPATH="/dev/socket/mdnsd"
        )
endif()