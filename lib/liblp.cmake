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

add_library(liblp STATIC
    ${SRC}/fs_mgr/liblp/builder.cpp
    ${SRC}/fs_mgr/liblp/super_layout_builder.cpp
    ${SRC}/fs_mgr/liblp/images.cpp
    ${SRC}/fs_mgr/liblp/partition_opener.cpp
    ${SRC}/fs_mgr/liblp/property_fetcher.cpp
    ${SRC}/fs_mgr/liblp/reader.cpp
    ${SRC}/fs_mgr/liblp/utility.cpp
    ${SRC}/fs_mgr/liblp/writer.cpp
    )

target_compile_definitions(liblp PRIVATE
    -D_FILE_OFFSET_BITS=64
    )

target_include_directories(liblp PUBLIC
    ${SRC}/fs_mgr/liblp/include
    ${SRC}/libbase/include
    ${SRC}/core/libcrypto_utils/include
    ${SRC}/core/libcutils/include
    ${SRC}/core/libsparse/include
    ${SRC}/extras/ext4_utils/include
    ${SRC}/logging/liblog/include
    ${SRC}/boringssl/include
    ${SRC}/../include
    )
