cmake_minimum_required(VERSION 3.20)

project(grpc-lite VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

option(GRPC_LITE_USE_SYSTEM_PROTOBUF "Use protobuf from the system" ON)
option(GRPC_LITE_USE_SYSTEM_NGHTTP2 "Use nghttp2 from the system" ON)
option(GRPC_LITE_USE_SYSTEM_LIBUV "Use libuv from the system" ON)
option(GRPC_LITE_ENABLE_OPENSSL "Enable TLS hooks through OpenSSL" OFF)
option(GRPC_LITE_ENABLE_CARES "Enable c-ares based resolver hooks" OFF)
option(GRPC_LITE_ENABLE_LOGGING "Enable spdlog/fmt logging hooks when present" OFF)
option(GRPC_LITE_BUILD_EXAMPLES "Build examples" ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

find_package(Threads REQUIRED)
find_package(PkgConfig REQUIRED)

if(GRPC_LITE_USE_SYSTEM_PROTOBUF)
  find_package(Protobuf CONFIG REQUIRED)
else()
  message(FATAL_ERROR "Vendored protobuf is not wired yet. Set GRPC_LITE_USE_SYSTEM_PROTOBUF=ON.")
endif()

if(TARGET protobuf::protoc)
  set(_PROTOBUF_PROTOC $<TARGET_FILE:protobuf::protoc>)
else()
  find_program(_PROTOBUF_PROTOC protoc REQUIRED)
endif()

if(GRPC_LITE_USE_SYSTEM_NGHTTP2)
  pkg_check_modules(NGHTTP2 REQUIRED IMPORTED_TARGET libnghttp2)
else()
  message(FATAL_ERROR "Vendored nghttp2 is not wired yet. Set GRPC_LITE_USE_SYSTEM_NGHTTP2=ON or add third_party/nghttp2 support.")
endif()

if(GRPC_LITE_USE_SYSTEM_LIBUV)
  pkg_check_modules(LIBUV REQUIRED IMPORTED_TARGET libuv)
else()
  message(FATAL_ERROR "Vendored libuv is not wired yet. Set GRPC_LITE_USE_SYSTEM_LIBUV=ON or add third_party/libuv support.")
endif()

set(_grpc_lite_optional_private_libs "")

if(GRPC_LITE_ENABLE_OPENSSL)
  find_package(OpenSSL REQUIRED)
  list(APPEND _grpc_lite_optional_private_libs OpenSSL::SSL OpenSSL::Crypto)
endif()

if(GRPC_LITE_ENABLE_CARES)
  pkg_check_modules(CARES REQUIRED IMPORTED_TARGET libcares)
  list(APPEND _grpc_lite_optional_private_libs PkgConfig::CARES)
endif()

if(GRPC_LITE_ENABLE_LOGGING)
  pkg_check_modules(SPDLOG IMPORTED_TARGET spdlog)
  pkg_check_modules(FMT IMPORTED_TARGET fmt)
endif()

add_library(grpc_lite STATIC
  src/channel.cc
  src/client_call.cc
  src/client_context.cc
  src/grpcpp_channel.cc
  src/grpcpp_server.cc
  src/server.cc
  src/server_builder.cc
  src/server_context.cc
  src/status.cc
  src/version.cc
  src/core/grpc_frame.cc
  src/core/http2_transport.cc
  src/core/uv_loop.cc
)

add_library(grpc_lite::grpc_lite ALIAS grpc_lite)

add_executable(protoc-gen-grpc_lite_upb tools/grpc_lite_upb_plugin.cc)
target_link_libraries(protoc-gen-grpc_lite_upb
  PRIVATE
    protobuf::libprotoc
    protobuf::libprotobuf
)

set(GRPC_LITE_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(GRPC_LITE_ECHO_PROTO "${CMAKE_CURRENT_SOURCE_DIR}/proto/echo.proto")
set(GRPC_LITE_ECHO_PROTO_RELATIVE "echo.proto")
set(GRPC_LITE_ECHO_UPB_HDR "${GRPC_LITE_GENERATED_DIR}/echo.upb.h")
set(GRPC_LITE_ECHO_UPB_MINITABLE_HDR "${GRPC_LITE_GENERATED_DIR}/echo.upb_minitable.h")
set(GRPC_LITE_ECHO_UPB_MINITABLE_SRC "${GRPC_LITE_GENERATED_DIR}/echo.upb_minitable.c")
set(GRPC_LITE_ECHO_GRPC_LITE_HDR "${GRPC_LITE_GENERATED_DIR}/echo.grpc_lite.upb.h")

add_custom_command(
  OUTPUT
    "${GRPC_LITE_ECHO_UPB_HDR}"
    "${GRPC_LITE_ECHO_UPB_MINITABLE_HDR}"
    "${GRPC_LITE_ECHO_UPB_MINITABLE_SRC}"
    "${GRPC_LITE_ECHO_GRPC_LITE_HDR}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${GRPC_LITE_GENERATED_DIR}"
  COMMAND
    ${_PROTOBUF_PROTOC}
    --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
    --plugin=protoc-gen-upb=$<TARGET_FILE:protobuf::protoc-gen-upb>
    --plugin=protoc-gen-upb_minitable=$<TARGET_FILE:protobuf::protoc-gen-upb_minitable>
    --plugin=protoc-gen-grpc_lite_upb=$<TARGET_FILE:protoc-gen-grpc_lite_upb>
    --upb_out=${GRPC_LITE_GENERATED_DIR}
    --upb_minitable_out=${GRPC_LITE_GENERATED_DIR}
    --grpc_lite_upb_out=${GRPC_LITE_GENERATED_DIR}
    ${GRPC_LITE_ECHO_PROTO_RELATIVE}
  DEPENDS
    "${GRPC_LITE_ECHO_PROTO}"
    protoc-gen-grpc_lite_upb
  VERBATIM
)

add_library(grpc_lite_echo_upb_proto STATIC
  "${GRPC_LITE_ECHO_UPB_MINITABLE_SRC}"
)

add_library(grpc_lite::echo_upb_proto ALIAS grpc_lite_echo_upb_proto)

target_include_directories(grpc_lite_echo_upb_proto
  PUBLIC
    "${GRPC_LITE_GENERATED_DIR}"
)

target_link_libraries(grpc_lite_echo_upb_proto
  PUBLIC
    protobuf::libupb
)

find_program(_GRPC_CPP_PLUGIN grpc_cpp_plugin)

set(GRPC_LITE_GRPC_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated_grpc")
set(GRPC_LITE_ECHO_PB_HDR "${GRPC_LITE_GRPC_GENERATED_DIR}/echo.pb.h")
set(GRPC_LITE_ECHO_PB_SRC "${GRPC_LITE_GRPC_GENERATED_DIR}/echo.pb.cc")
set(GRPC_LITE_ECHO_GRPC_PB_HDR "${GRPC_LITE_GRPC_GENERATED_DIR}/echo.grpc.pb.h")
set(GRPC_LITE_ECHO_GRPC_PB_SRC "${GRPC_LITE_GRPC_GENERATED_DIR}/echo.grpc.pb.cc")

add_custom_command(
  OUTPUT
    "${GRPC_LITE_ECHO_PB_HDR}"
    "${GRPC_LITE_ECHO_PB_SRC}"
    "${GRPC_LITE_ECHO_GRPC_PB_HDR}"
    "${GRPC_LITE_ECHO_GRPC_PB_SRC}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${GRPC_LITE_GRPC_GENERATED_DIR}"
  COMMAND
    ${_PROTOBUF_PROTOC}
    --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/proto
    --cpp_out=${GRPC_LITE_GRPC_GENERATED_DIR}
    --grpc_out=${GRPC_LITE_GRPC_GENERATED_DIR}
    --plugin=protoc-gen-grpc=${_GRPC_CPP_PLUGIN}
    ${GRPC_LITE_ECHO_PROTO_RELATIVE}
  DEPENDS
    "${GRPC_LITE_ECHO_PROTO}"
  VERBATIM
)

add_library(grpc_lite_echo_grpc_proto STATIC
  "${GRPC_LITE_ECHO_PB_SRC}"
  "${GRPC_LITE_ECHO_GRPC_PB_SRC}"
)

add_library(grpc_lite::echo_grpc_proto ALIAS grpc_lite_echo_grpc_proto)

target_include_directories(grpc_lite_echo_grpc_proto
  PUBLIC
    "${GRPC_LITE_GRPC_GENERATED_DIR}"
)

target_link_libraries(grpc_lite_echo_grpc_proto
  PUBLIC
    grpc_lite::grpc_lite
)

target_include_directories(grpc_lite
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(grpc_lite
  PUBLIC
    protobuf::libprotobuf
  PRIVATE
    Threads::Threads
    PkgConfig::NGHTTP2
    PkgConfig::LIBUV
    ${_grpc_lite_optional_private_libs}
)

target_compile_definitions(grpc_lite
  PRIVATE
    $<$<BOOL:${GRPC_LITE_ENABLE_OPENSSL}>:GRPC_LITE_HAS_OPENSSL=1>
    $<$<BOOL:${GRPC_LITE_ENABLE_CARES}>:GRPC_LITE_HAS_CARES=1>
    $<$<BOOL:${GRPC_LITE_ENABLE_LOGGING}>:GRPC_LITE_HAS_LOGGING=1>
)

if(TARGET PkgConfig::SPDLOG)
  target_link_libraries(grpc_lite PRIVATE PkgConfig::SPDLOG)
endif()

if(TARGET PkgConfig::FMT)
  target_link_libraries(grpc_lite PRIVATE PkgConfig::FMT)
endif()

if(GRPC_LITE_BUILD_EXAMPLES)
  add_executable(grpc_lite_architecture examples/architecture.cc)
  target_link_libraries(grpc_lite_architecture PRIVATE grpc_lite::grpc_lite)

  add_executable(grpc_lite_echo_server examples/echo_server.cc)
  target_link_libraries(grpc_lite_echo_server PRIVATE grpc_lite::grpc_lite)

  add_executable(grpc_lite_proto_echo_server examples/proto_echo_server.cc)
  target_link_libraries(grpc_lite_proto_echo_server
    PRIVATE
      grpc_lite::grpc_lite
      grpc_lite::echo_upb_proto
  )

  add_executable(grpc_lite_proto_echo_client examples/proto_echo_client.cc)
  target_link_libraries(grpc_lite_proto_echo_client
    PRIVATE
      grpc_lite::grpc_lite
      grpc_lite::echo_upb_proto
  )

  add_executable(grpc_lite_grpc_echo_server examples/grpc_echo_server.cc)
  target_link_libraries(grpc_lite_grpc_echo_server
    PRIVATE
      grpc_lite::echo_grpc_proto
  )

  add_executable(grpc_lite_grpc_echo_client examples/grpc_echo_client.cc)
  target_link_libraries(grpc_lite_grpc_echo_client
    PRIVATE
      grpc_lite::echo_grpc_proto
  )
endif()

install(TARGETS grpc_lite EXPORT grpc_liteTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/grpc_liteConfigVersion.cmake"
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion
)

configure_package_config_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/grpc_liteConfig.cmake.in"
  "${CMAKE_CURRENT_BINARY_DIR}/grpc_liteConfig.cmake"
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/grpc_lite
)

install(FILES
  "${CMAKE_CURRENT_BINARY_DIR}/grpc_liteConfig.cmake"
  "${CMAKE_CURRENT_BINARY_DIR}/grpc_liteConfigVersion.cmake"
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/grpc_lite
)

install(EXPORT grpc_liteTargets
  FILE grpc_liteTargets.cmake
  NAMESPACE grpc_lite::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/grpc_lite
)
