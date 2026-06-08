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

add_library(libselinux STATIC
    ${SRC}/selinux/libselinux/src/booleans.c
    ${SRC}/selinux/libselinux/src/callbacks.c
    ${SRC}/selinux/libselinux/src/canonicalize_context.c
    ${SRC}/selinux/libselinux/src/checkAccess.c
    ${SRC}/selinux/libselinux/src/check_context.c
    ${SRC}/selinux/libselinux/src/compute_av.c
    ${SRC}/selinux/libselinux/src/compute_create.c
    ${SRC}/selinux/libselinux/src/compute_member.c
    ${SRC}/selinux/libselinux/src/context.c
    ${SRC}/selinux/libselinux/src/deny_unknown.c
    ${SRC}/selinux/libselinux/src/disable.c
    ${SRC}/selinux/libselinux/src/enabled.c
    ${SRC}/selinux/libselinux/src/freecon.c
    ${SRC}/selinux/libselinux/src/get_initial_context.c
    ${SRC}/selinux/libselinux/src/getenforce.c
    ${SRC}/selinux/libselinux/src/hashtab.c
    ${SRC}/selinux/libselinux/src/init.c
    ${SRC}/selinux/libselinux/src/label.c
    ${SRC}/selinux/libselinux/src/label_backends_android.c
    ${SRC}/selinux/libselinux/src/label_file.c
    ${SRC}/selinux/libselinux/src/label_support.c
    ${SRC}/selinux/libselinux/src/mapping.c
    ${SRC}/selinux/libselinux/src/matchpathcon.c
    ${SRC}/selinux/libselinux/src/policyvers.c
    ${SRC}/selinux/libselinux/src/procattr.c
    ${SRC}/selinux/libselinux/src/regex.c
    ${SRC}/selinux/libselinux/src/reject_unknown.c
    ${SRC}/selinux/libselinux/src/selinux_config.c
    ${SRC}/selinux/libselinux/src/selinux_internal.c
    ${SRC}/selinux/libselinux/src/sestatus.c
    ${SRC}/selinux/libselinux/src/seusers.c
    ${SRC}/selinux/libselinux/src/setenforce.c
    ${SRC}/selinux/libselinux/src/setrans_client.c
    ${SRC}/selinux/libselinux/src/sha1.c
    ${SRC}/selinux/libselinux/src/stringrep.c
    )

# Linux-only sources, built on the linux-kernel platforms (Android + host Linux)
# only; macOS/Windows hosts can't compile them and the host tools don't use them:
#  - the userspace AVC (avc*.c) talks to the kernel over netlink and pulls in
#    <linux/netlink.h>/<poll.h>;
#  - the android/ backend pulls in <fnmatch.h> (android.c) and <linux/magic.h>
#    (android_seapp.c) and exposes the device-side selinux_android_* APIs;
#  - the *filecon get/set a single file's security context via the Linux 5-arg
#    *xattr API (no __APPLE__ handling, unlike the selabel backend label_file.c),
#    which the host tools don't use;
#  - load_policy.c mounts selinuxfs/proc via the Linux 5-arg mount(2) + umount/
#    umount2 (macOS has only the 4-arg BSD mount(); mingw neither), to load policy
#    into the running kernel -- a device-only operation (callers live in core/init
#    and policycoreutils, not the host tools, and nothing else in libselinux
#    references its symbols).
if(PLATFORM_LINUX_KERNEL)
    target_sources(libselinux PRIVATE
        ${SRC}/selinux/libselinux/src/avc.c
        ${SRC}/selinux/libselinux/src/avc_internal.c
        ${SRC}/selinux/libselinux/src/avc_sidtab.c
        ${SRC}/selinux/libselinux/src/load_policy.c
        ${SRC}/selinux/libselinux/src/android/android.c
        ${SRC}/selinux/libselinux/src/android/android_seapp.c
        ${SRC}/selinux/libselinux/src/fgetfilecon.c
        ${SRC}/selinux/libselinux/src/fsetfilecon.c
        ${SRC}/selinux/libselinux/src/getfilecon.c
        ${SRC}/selinux/libselinux/src/lgetfilecon.c
        ${SRC}/selinux/libselinux/src/lsetfilecon.c
        ${SRC}/selinux/libselinux/src/setfilecon.c
        # getpeercon reads a socket peer's context via getsockopt(SO_PEERSEC);
        # needs <sys/socket.h>/netlink, absent on mingw and unused by host tools.
        ${SRC}/selinux/libselinux/src/getpeercon.c
        )
endif()

# target.android (Android.bp libselinux): android_device.c
if(PLATFORM_ANDROID)
    target_sources(libselinux PRIVATE
        ${SRC}/selinux/libselinux/src/android/android_device.c
        )
endif()

target_compile_definitions(libselinux PRIVATE
    -DAUDITD_LOG_TAG=1003
    -D_GNU_SOURCE
    -DHOST
    -DUSE_PCRE2
    -DNO_PERSISTENTLY_STORED_PATTERNS
    -DDISABLE_SETRANS
    -DDISABLE_BOOL
    -DNO_MEDIA_BACKEND
    -DNO_X_BACKEND
    -DNO_DB_BACKEND
    -DPCRE2_CODE_UNIT_WIDTH=8
    )

# Per-OS cflags (Android.bp libselinux target.{host,android})
if(PLATFORM_HOST)
    target_compile_definitions(libselinux PRIVATE -DBUILD_HOST -DHAVE_REALLOCARRAY)
else()
    target_compile_definitions(libselinux PRIVATE -DHAVE_STRLCPY -DHAVE_REALLOCARRAY)
endif()
    
target_include_directories(libselinux PRIVATE
    ${SRC}/selinux/libselinux/include 
    ${SRC}/selinux/libselinux/src
    ${SRC}/selinux/libsepol/include
    ${SRC}/core/libcutils/include
    ${SRC}/logging/liblog/include 
    ${SRC}/core/libpackagelistparser/include
    ${SRC}/pcre/include
    ${SRC}/../include
    )

# The macOS/mingw host builds need no compat-header shims here: the Linux-isms
# libselinux would otherwise hit on a host (selinuxfs/proc mount probe,
# __fsetlocking, O_CLOEXEC, stpcpy, getxattr) are guarded directly in the source
# by patches/selinux/0001-host-portability-guards.patch (applied by
# scripts/patch-source.sh), and the kernel-only translation units are excluded
# above under PLATFORM_LINUX_KERNEL.
