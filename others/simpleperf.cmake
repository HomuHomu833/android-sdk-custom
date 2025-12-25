set(SIMPLEPERF_DIR ${SRC}/system/extras/simpleperf)
set(SIMPLEPERF_NONLINUX ${SIMPLEPERF_DIR}/nonlinux_support)

add_compile_definitions(
    USE_BIONIC_UAPI_HEADERS
    NO_LIBDEXFILE_SUPPORT
)

set(SIMPLEPERF_CFLAGS
    -fvisibility=hidden
    -Wno-unused-parameter
    -Wno-switch
    -Wno-implicit-fallthrough
)

set(SIMPLEPERF_INCLUDES
    ${SIMPLEPERF_DIR}
    ${SIMPLEPERF_NONLINUX}/include
    ${SRC}/libbase/include
    ${SRC}/logging/liblog/include
    ${SRC}/libziparchive/include
    ${SRC}/libutils/include
    ${SRC}/libz/include
    ${SRC}/libzstd/include
    ${SRC}/liblzma/include
    ${SRC}/fmtlib/include
    ${SRC}/protobuf/src
    ${SRC}/bionic/libc/kernel
    ${SRC}/soong/cc/libbuildversion/include
    ${CMAKE_PREFIX_PATH}/include
)

file(GLOB SIMPLEPERF_PROTO ${SIMPLEPERF_DIR}/*.proto)

set(SIMPLEPERF_PROTO_SRCS)
set(SIMPLEPERF_PROTO_HDRS)

foreach(proto ${SIMPLEPERF_PROTO})
    get_filename_component(name ${proto} NAME_WE)

    set(cc ${CMAKE_CURRENT_BINARY_DIR}/${name}.pb.cc)
    set(h  ${CMAKE_CURRENT_BINARY_DIR}/${name}.pb.h)

    add_custom_command(
        OUTPUT ${cc} ${h}
        COMMAND ${PROTOC_COMPILER}
            --proto_path=${SIMPLEPERF_DIR}
            --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
            ${proto}
        DEPENDS ${proto}
    )

    list(APPEND SIMPLEPERF_PROTO_SRCS ${cc})
    list(APPEND SIMPLEPERF_PROTO_HDRS ${h})
endforeach()

set_source_files_properties(
    ${SIMPLEPERF_PROTO_SRCS} ${SIMPLEPERF_PROTO_HDRS}
    PROPERTIES GENERATED TRUE
)

add_library(libsimpleperf_regex STATIC
    ${SIMPLEPERF_DIR}/RegEx.cpp
)
target_compile_options(libsimpleperf_regex PRIVATE -fexceptions)
target_include_directories(libsimpleperf_regex PRIVATE ${SIMPLEPERF_INCLUDES})
target_link_libraries(libsimpleperf_regex libbase)

add_library(libsimpleperf_etm_decoder STATIC
    ${SIMPLEPERF_DIR}/ETMDecoder.cpp
)
target_compile_options(libsimpleperf_etm_decoder PRIVATE
    -fexceptions
    -Wno-unused-private-field
)
target_include_directories(libsimpleperf_etm_decoder PRIVATE ${SIMPLEPERF_INCLUDES})
target_link_libraries(libsimpleperf_etm_decoder
    libopencsd_decoder
    libbase
    liblog
)

set(SIMPLEPERF_SRCS
    cmd_dumprecord.cpp
    cmd_help.cpp
    cmd_inject.cpp
    cmd_kmem.cpp
    cmd_merge.cpp
    cmd_report.cpp
    cmd_report_sample.cpp
    command.cpp
    dso.cpp
    BranchListFile.cpp
    event_attr.cpp
    event_type.cpp
    kallsyms.cpp
    perf_regs.cpp
    read_apk.cpp
    read_elf.cpp
    read_symbol_map.cpp
    record.cpp
    RecordFilter.cpp
    record_file_reader.cpp
    record_file_writer.cpp
    report_utils.cpp
    thread_tree.cpp
    tracing.cpp
    utils.cpp
    ZstdUtil.cpp
    nonlinux_support/nonlinux_support.cpp
)

list(TRANSFORM SIMPLEPERF_SRCS PREPEND ${SIMPLEPERF_DIR}/)

add_library(libsimpleperf STATIC
    ${SIMPLEPERF_SRCS}
    ${SIMPLEPERF_PROTO_SRCS}
)

target_compile_options(libsimpleperf PRIVATE ${SIMPLEPERF_CFLAGS})
target_include_directories(libsimpleperf PRIVATE
    ${SIMPLEPERF_INCLUDES}
    ${CMAKE_CURRENT_BINARY_DIR}
)

target_link_libraries(libsimpleperf
    libsimpleperf_etm_decoder
    libsimpleperf_regex
    libbase
    liblog
    liblzma
    libutils
    libprotobuf-lite
    libopencsd_decoder
    libz
    libziparchive
    libzstd
    fmt::fmt
)

add_executable(simpleperf
    ${SIMPLEPERF_DIR}/main.cpp
)

target_compile_options(simpleperf PRIVATE ${SIMPLEPERF_CFLAGS})
target_include_directories(simpleperf PRIVATE ${SIMPLEPERF_INCLUDES})

target_link_libraries(simpleperf
    libsimpleperf
    dl
    pthread
    rt
)
