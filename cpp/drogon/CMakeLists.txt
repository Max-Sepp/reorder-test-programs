cmake_minimum_required(VERSION 3.16)
project(drogon_server CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Drogon is installed via vcpkg (see vcpkg.json). Configure with:
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake
find_package(Drogon CONFIG REQUIRED)

add_executable(drogon_server src/main.cpp)
target_link_libraries(drogon_server PRIVATE Drogon::Drogon)

# Default location of the static asset files (project-root/assets).
# Override at runtime with the ASSETS_DIR environment variable.
target_compile_definitions(drogon_server
  PRIVATE DEFAULT_ASSETS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../assets")
