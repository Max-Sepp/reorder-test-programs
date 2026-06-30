cmake_minimum_required(VERSION 3.16)
project(crow_server CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Crow is installed via vcpkg (see vcpkg.json). Configure with:
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake
find_package(Crow CONFIG REQUIRED)

add_executable(crow_server src/main.cpp)
target_link_libraries(crow_server PRIVATE Crow::Crow)

# Default location of the static asset files (project-root/assets).
# Override at runtime with the ASSETS_DIR environment variable.
target_compile_definitions(crow_server
  PRIVATE DEFAULT_ASSETS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../assets")
