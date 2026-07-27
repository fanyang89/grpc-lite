cmake_minimum_required(VERSION 3.20)
project(grpc_lite_cpp_consumer LANGUAGES CXX)

find_package(grpc_lite 0.3 CONFIG REQUIRED)

add_executable(grpc_lite_cpp_consumer main.cc)
target_link_libraries(grpc_lite_cpp_consumer PRIVATE grpc_lite::grpcpp)
