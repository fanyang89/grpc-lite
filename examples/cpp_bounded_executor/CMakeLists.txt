cmake_minimum_required(VERSION 3.20)
project(grpc_lite_bounded_executor_example LANGUAGES C CXX)

# Use a same-version source tree plus its extracted generated-C release asset.
if(NOT GRPC_LITE_SOURCE_DIR)
  message(FATAL_ERROR "GRPC_LITE_SOURCE_DIR is required")
endif()
find_package(Threads REQUIRED)
add_subdirectory("${GRPC_LITE_SOURCE_DIR}" grpc-lite)

add_executable(grpc_lite_bounded_executor main.cc)
target_compile_features(grpc_lite_bounded_executor PRIVATE cxx_std_17)
target_link_libraries(grpc_lite_bounded_executor PRIVATE grpc_lite::c Threads::Threads)

enable_testing()
foreach(scenario IN ITEMS success overload shutdown)
  add_test(NAME bounded_executor_${scenario}
    COMMAND grpc_lite_bounded_executor "${scenario}")
  set_tests_properties(bounded_executor_${scenario} PROPERTIES TIMEOUT 20)
endforeach()
