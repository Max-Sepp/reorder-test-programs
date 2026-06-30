cmake_minimum_required(VERSION 3.16)
project(httplib_server CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# cpp-httplib is installed via vcpkg (see vcpkg.json). Configure with:
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake
find_package(httplib CONFIG REQUIRED)

# Compile-time endpoint selection (ENDPOINT_* options).
include(${CMAKE_CURRENT_SOURCE_DIR}/../endpoints.cmake)

add_executable(httplib_server src/main.cpp)
target_link_libraries(httplib_server PRIVATE httplib::httplib)
configure_endpoints(httplib_server)

# Default location of the static asset files (project-root/assets).
# Override at runtime with the ASSETS_DIR environment variable.
target_compile_definitions(httplib_server
  PRIVATE DEFAULT_ASSETS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../assets")
