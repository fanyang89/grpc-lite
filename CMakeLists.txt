cmake_minimum_required(VERSION 3.20)
project(grpc_lite VERSION 0.4.0 LANGUAGES C)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "grpc-lite currently supports Linux only")
endif()

find_program(GRPC_LITE_ZIG_EXECUTABLE NAMES zig REQUIRED)
execute_process(
  COMMAND "${GRPC_LITE_ZIG_EXECUTABLE}" version
  OUTPUT_VARIABLE GRPC_LITE_ZIG_VERSION
  OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)
if(GRPC_LITE_ZIG_VERSION VERSION_LESS 0.16.0)
  message(FATAL_ERROR
    "grpc-lite requires Zig 0.16.0 or newer; found ${GRPC_LITE_ZIG_VERSION}")
endif()

find_package(Threads REQUIRED)

option(GRPC_LITE_ENABLE_TLS "Enable TLS transport support through mbedTLS" OFF)
set(GRPC_LITE_ZIG_OPTIMIZE "" CACHE STRING
  "Override the Zig optimization mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)")
set_property(CACHE GRPC_LITE_ZIG_OPTIMIZE PROPERTY STRINGS
  "" Debug ReleaseSafe ReleaseFast ReleaseSmall)

if(GRPC_LITE_ENABLE_TLS)
  set(_grpc_lite_tls true)
else()
  set(_grpc_lite_tls false)
endif()

get_property(_grpc_lite_multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(_grpc_lite_multi_config)
  set(_grpc_lite_prefix "${CMAKE_CURRENT_BINARY_DIR}/zig-out/$<CONFIG>")
  set(_grpc_lite_cache_dir "${CMAKE_CURRENT_BINARY_DIR}/zig-cache/$<CONFIG>")
else()
  set(_grpc_lite_prefix "${CMAKE_CURRENT_BINARY_DIR}/zig-out")
  set(_grpc_lite_cache_dir "${CMAKE_CURRENT_BINARY_DIR}/zig-cache")
endif()

if(GRPC_LITE_ZIG_OPTIMIZE)
  set(_grpc_lite_optimize "${GRPC_LITE_ZIG_OPTIMIZE}")
else()
  set(_grpc_lite_optimize
    "$<IF:$<CONFIG:Debug>,Debug,$<IF:$<CONFIG:Release>,ReleaseFast,$<IF:$<CONFIG:MinSizeRel>,ReleaseSmall,ReleaseSafe>>>")
endif()

set(_grpc_lite_static_library "${_grpc_lite_prefix}/lib/libgrpc_lite.a")
set(_grpc_lite_shared_library "${_grpc_lite_prefix}/lib/libgrpc_lite.so")
set(_grpc_lite_shared_soname "${_grpc_lite_prefix}/lib/libgrpc_lite.so.1")
set(_grpc_lite_shared_real "${_grpc_lite_prefix}/lib/libgrpc_lite.so.1.0.0")

add_custom_target(grpc_lite_zig_build
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_grpc_lite_prefix}"
  COMMAND "${GRPC_LITE_ZIG_EXECUTABLE}" build install-c-sdk
    -Dprotobuf=false
    "-Dtls=${_grpc_lite_tls}"
    "-Doptimize=${_grpc_lite_optimize}"
    --prefix "${_grpc_lite_prefix}"
    --cache-dir "${_grpc_lite_cache_dir}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  BYPRODUCTS
    "${_grpc_lite_static_library}"
    "${_grpc_lite_shared_library}"
    "${_grpc_lite_shared_soname}"
    "${_grpc_lite_shared_real}"
  COMMENT "Building grpc-lite C libraries with Zig"
  VERBATIM
  USES_TERMINAL)

function(_grpc_lite_set_imported_location target filename)
  set_target_properties(${target} PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_BINARY_DIR}/zig-out/lib/${filename}")
  if(_grpc_lite_multi_config)
    foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
      string(TOUPPER "${config}" config_upper)
      set_target_properties(${target} PROPERTIES
        "IMPORTED_LOCATION_${config_upper}"
          "${CMAKE_CURRENT_BINARY_DIR}/zig-out/${config}/lib/${filename}")
    endforeach()
  endif()
endfunction()

add_library(grpc_lite_c SHARED IMPORTED GLOBAL)
_grpc_lite_set_imported_location(grpc_lite_c "libgrpc_lite.so")
set_target_properties(grpc_lite_c PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include")
add_dependencies(grpc_lite_c grpc_lite_zig_build)
add_library(grpc_lite::c ALIAS grpc_lite_c)

add_library(grpc_lite_c_static STATIC IMPORTED GLOBAL)
_grpc_lite_set_imported_location(grpc_lite_c_static "libgrpc_lite.a")
set_target_properties(grpc_lite_c_static PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  INTERFACE_LINK_LIBRARIES "Threads::Threads;${CMAKE_DL_LIBS};m;rt")
add_dependencies(grpc_lite_c_static grpc_lite_zig_build)
add_library(grpc_lite::c_static ALIAS grpc_lite_c_static)
