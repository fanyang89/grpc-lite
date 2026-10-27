cmake_minimum_required(VERSION 3.20)
project(grpc_lite_public_cpp_consumer LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(grpc_lite CONFIG REQUIRED COMPONENTS protobuf)

# Each supported header must work as the first include, without source-tree paths.
set(public_headers
  grpc_lite/grpc_lite.h grpc_lite/grpc_lite.hpp
  grpc_lite/cpp/channel.hpp grpc_lite/cpp/client_stream.hpp
  grpc_lite/cpp/metadata.hpp grpc_lite/cpp/runtime.hpp
  grpc_lite/cpp/server.hpp grpc_lite/cpp/status.hpp
  grpc_lite/cpp/sync_service.hpp grpc_lite/cpp/typed_service.hpp
  grpcpp/grpcpp.h grpcpp/channel.h grpcpp/channel_arguments.h
  grpcpp/client_context.h grpcpp/create_channel.h grpcpp/server_context.h
  grpcpp/security/credentials.h grpcpp/support/status.h
  grpcpp/support/status_code_enum.h grpcpp/support/stub_options.h
  grpcpp/support/sync_stream.h)
foreach(header IN LISTS public_headers)
  string(MAKE_C_IDENTIFIER "${header}" name)
  set(source "${CMAKE_CURRENT_BINARY_DIR}/${name}.cc")
  file(WRITE "${source}" "#include <${header}>\n")
  add_library("header_${name}" OBJECT "${source}")
  target_link_libraries("header_${name}" PRIVATE grpc_lite::grpcpp)
  target_compile_options("header_${name}" PRIVATE -Wall -Wextra -Werror)
endforeach()

set(generated "${CMAKE_CURRENT_BINARY_DIR}/generated")
add_custom_command(
  OUTPUT "${generated}/api.pb.cc" "${generated}/api.pb.h"
         "${generated}/api.grpc.pb.cc" "${generated}/api.grpc.pb.h"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${generated}"
  COMMAND "$<TARGET_FILE:protobuf::protoc>"
    "--proto_path=${CMAKE_CURRENT_SOURCE_DIR}"
    "--cpp_out=${generated}"
    "--plugin=protoc-gen-grpc_lite_cpp=$<TARGET_FILE:grpc_lite::protoc-gen-grpc_lite_cpp>"
    "--grpc_lite_cpp_out=${generated}"
    "${CMAKE_CURRENT_SOURCE_DIR}/api.proto"
  DEPENDS api.proto protobuf::protoc grpc_lite::protoc-gen-grpc_lite_cpp
  VERBATIM)
add_executable(public_cpp_consumer main.cc
  "${generated}/api.pb.cc" "${generated}/api.grpc.pb.cc")
target_include_directories(public_cpp_consumer PRIVATE "${generated}")
target_link_libraries(public_cpp_consumer PRIVATE grpc_lite::grpcpp_protobuf)
target_compile_features(public_cpp_consumer PRIVATE cxx_std_17)
target_compile_options(public_cpp_consumer PRIVATE -Wall -Wextra -Werror)
enable_testing()
add_test(NAME public_cpp_consumer COMMAND public_cpp_consumer)
set_tests_properties(public_cpp_consumer PROPERTIES TIMEOUT 30)
