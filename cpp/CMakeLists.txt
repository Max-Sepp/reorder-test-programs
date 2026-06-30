cmake_minimum_required(VERSION 3.16)
project(reorder_test_programs CXX)

# Single global configuration for every server implementation.
#
# Configuring this aggregate project builds all servers in one tree and emits a
# single compile_commands.json (in the build directory), so editor IntelliSense
# / clangd can be pointed at one file that covers the whole repository:
#
#   cmake -S cpp -B build -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
#   cmake --build build
#
# vcpkg installs each server's dependencies from the cpp/vcpkg.json manifest.
# Each cpp/<name> subdirectory is also a standalone CMake project and can still
# be configured on its own (see the per-implementation README).

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Emit compile_commands.json for IntelliSense / clangd.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_subdirectory(crow)
add_subdirectory(cpp-httplib)
# add_subdirectory(drogon)  # planned
