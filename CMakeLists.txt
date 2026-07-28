cmake_minimum_required(VERSION 3.20)
project(grpc_lite VERSION 0.4.0 LANGUAGES C)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "grpc-lite currently supports Linux only")
endif()
if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  message(FATAL_ERROR "The checked-in grpc-lite C sources currently support x86_64 only")
endif()

find_package(Threads REQUIRED)
include(FetchContent)

option(GRPC_LITE_ENABLE_TLS "Enable TLS transport support through mbedTLS" OFF)
if(GRPC_LITE_ENABLE_TLS)
  message(FATAL_ERROR "TLS is not yet available in the transpiled C source build")
endif()

set(_grpc_lite_runtime_source "${CMAKE_CURRENT_SOURCE_DIR}/transpiled/src/grpc_lite.c")
set(_grpc_lite_plugin_source
  "${CMAKE_CURRENT_SOURCE_DIR}/transpiled/src/protoc-gen-grpc_lite_cpp.c")
if(NOT EXISTS "${_grpc_lite_runtime_source}" OR NOT EXISTS "${_grpc_lite_plugin_source}")
  message(FATAL_ERROR "grpc-lite transpiled sources are missing; run 'mise run transpile-c'")
endif()

if(NOT TARGET nghttp2)
  set(ENABLE_LIB_ONLY ON)
  set(BUILD_SHARED_LIBS OFF)
  set(BUILD_STATIC_LIBS ON)
  set(BUILD_TESTING OFF)
  set(ENABLE_DOC OFF)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/nghttp2/CMakeLists.txt")
    add_subdirectory(third_party/nghttp2 EXCLUDE_FROM_ALL)
  else()
    FetchContent_Declare(
      grpc_lite_nghttp2
      URL https://codeload.github.com/nghttp2/nghttp2/tar.gz/68cb6900fde14c77f0cd7add0e094a862960eb99
      URL_HASH SHA256=3f042e5284ad349f837b65dd5be953b34c007a05259119092dbe6ebeaa73d306
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(grpc_lite_nghttp2)
  endif()
endif()

if(NOT TARGET c-ares::cares)
  set(CARES_STATIC ON CACHE BOOL "" FORCE)
  set(CARES_SHARED OFF CACHE BOOL "" FORCE)
  set(CARES_INSTALL OFF CACHE BOOL "" FORCE)
  set(CARES_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(CARES_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(
    grpc_lite_cares
    URL https://github.com/c-ares/c-ares/releases/download/v1.34.8/c-ares-1.34.8.tar.gz
    URL_HASH SHA256=c222b6d681096f9444d2c4863d2c1174019e27cacca0a4a5c114d36dd7d7bf78
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
  FetchContent_MakeAvailable(grpc_lite_cares)
endif()

add_library(grpc_lite_c STATIC
  "${_grpc_lite_runtime_source}"
  src/cpucycles_compat.c)
target_compile_features(grpc_lite_c PRIVATE c_std_11)
set_target_properties(grpc_lite_c PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED TRUE)
target_include_directories(grpc_lite_c
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/transpiled/include")
target_link_libraries(grpc_lite_c
  PUBLIC Threads::Threads ${CMAKE_DL_LIBS} m rt
  PRIVATE nghttp2 c-ares::cares)
add_library(grpc_lite::c ALIAS grpc_lite_c)
add_library(grpc_lite::c_static ALIAS grpc_lite_c)

add_library(grpc_lite_grpcpp INTERFACE)
target_compile_features(grpc_lite_grpcpp INTERFACE cxx_std_17)
target_include_directories(grpc_lite_grpcpp INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(grpc_lite_grpcpp INTERFACE grpc_lite_c)
add_library(grpc_lite::grpcpp ALIAS grpc_lite_grpcpp)

add_executable(grpc_lite_protoc_gen EXCLUDE_FROM_ALL "${_grpc_lite_plugin_source}")
target_compile_features(grpc_lite_protoc_gen PRIVATE c_std_11)
set_target_properties(grpc_lite_protoc_gen PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED TRUE)
target_include_directories(grpc_lite_protoc_gen PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/transpiled/include")
target_link_libraries(grpc_lite_protoc_gen PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m rt)
target_link_options(grpc_lite_protoc_gen PRIVATE -nostartfiles)
set_target_properties(grpc_lite_protoc_gen PROPERTIES OUTPUT_NAME protoc-gen-grpc_lite_cpp)
add_executable(grpc_lite::protoc-gen-grpc_lite_cpp ALIAS grpc_lite_protoc_gen)
