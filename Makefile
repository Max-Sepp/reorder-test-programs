# Build driver for the reorder test programs.
#
# Each C++ project under cpp/<name> is built with CMake + vcpkg. For every
# project there are three targets:
#
#   make <name>-debug     configure + build a Debug build   (cpp/<name>/build-debug)
#   make <name>-release   configure + build a Release build (cpp/<name>/build-release)
#   make <name>-clean     remove both build directories
#
# e.g. `make crow-debug`, `make crow-release`.
#
# vcpkg is located via VCPKG_ROOT (override on the command line if needed):
#   make crow-release VCPKG_ROOT=/path/to/vcpkg

VCPKG_ROOT ?= $(HOME)/.vcpkg/vcpkg
TOOLCHAIN  := $(VCPKG_ROOT)/scripts/buildsystems/vcpkg.cmake

# This project builds exclusively with clang. CXX is a Make built-in (defaults
# to g++), so force it with := rather than ?=; override on the command line with
# `make CXX=... <target>` if needed.
CXX := clang++

# Extra args forwarded to every CMake configure, e.g. to exclude endpoints at
# compile time:
#   make crow-release EXTRA_CMAKE_ARGS="-DENDPOINT_BIGFILE=OFF -DENDPOINT_LOG=OFF"
EXTRA_CMAKE_ARGS ?=
CMAKE_FLAGS := -DCMAKE_TOOLCHAIN_FILE="$(TOOLCHAIN)" -DCMAKE_CXX_COMPILER="$(CXX)" $(EXTRA_CMAKE_ARGS)

# Projects that have a CMake build (add new implementations here).
PROJECTS := crow cpp-httplib drogon

.PHONY: all debug release clean clean-all help compile-commands

help:
	@echo "Targets:"
	@echo "  make <name>-debug      Debug build   -> cpp/<name>/build-debug"
	@echo "  make <name>-release    Release build -> cpp/<name>/build-release"
	@echo "  make <name>-clean      Remove a project's build directories"
	@echo "  make debug | release   Build every project in that configuration"
	@echo "  make clean             Remove every build directory"
	@echo "  make clean-all         Remove every directory matching build* in the tree"
	@echo "  make compile-commands  Configure the global build -> build/compile_commands.json"
	@echo ""
	@echo "Exclude endpoints at compile time via EXTRA_CMAKE_ARGS, e.g.:"
	@echo "  make crow-release EXTRA_CMAKE_ARGS=\"-DENDPOINT_BIGFILE=OFF\""
	@echo ""
	@echo "Projects: $(PROJECTS)"

# Configure the aggregate project (cpp/CMakeLists.txt) to generate a single
# build/compile_commands.json covering every implementation, for editor
# IntelliSense / clangd. Configures only; it does not compile anything.
compile-commands:
	cmake -S cpp -B build $(CMAKE_FLAGS) -DCMAKE_BUILD_TYPE=Debug

# Aggregate targets across all projects.
all: release
debug:   $(addsuffix -debug,$(PROJECTS))
release: $(addsuffix -release,$(PROJECTS))
clean:   $(addsuffix -clean,$(PROJECTS))
	rm -rf build

# Remove every directory matching build* anywhere in the tree (e.g. the root
# build/ and each cpp/<name>/build-debug, build-release).
clean-all:
	find . -type d -name 'build*' -prune -exec rm -rf {} +

# Generate <name>-debug / <name>-release / <name>-clean for each project.
define PROJECT_template
.PHONY: $(1)-debug $(1)-release $(1)-clean

$(1)-debug:
	cmake -S cpp/$(1) -B cpp/$(1)/build-debug \
		$(CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Debug
	cmake --build cpp/$(1)/build-debug

$(1)-release:
	cmake -S cpp/$(1) -B cpp/$(1)/build-release \
		$(CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release
	cmake --build cpp/$(1)/build-release

$(1)-clean:
	rm -rf cpp/$(1)/build-debug cpp/$(1)/build-release
endef

$(foreach p,$(PROJECTS),$(eval $(call PROJECT_template,$(p))))
