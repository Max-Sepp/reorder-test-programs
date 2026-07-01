# Build driver for the reorder test programs.
#
# Each C++ project under cpp/<name> is built with CMake + vcpkg; each Rust
# project under rust/<name> is built with Cargo (a single workspace in rust/).
# For every project there are three targets:
#
#   make <name>-debug     configure + build a Debug build
#   make <name>-release   configure + build a Release build
#   make <name>-clean     remove that project's build artifacts
#
# e.g. `make crow-debug`, `make crow-release`, `make axum-release`.
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

# Extra args forwarded to every Cargo build, e.g. to exclude endpoints at
# compile time (features are all on by default):
#   make axum-release EXTRA_CARGO_ARGS="--no-default-features --features echo,log"
EXTRA_CARGO_ARGS ?=

# C++ projects (CMake + vcpkg) and Rust projects (Cargo workspace in rust/).
# Add new implementations to the matching list.
PROJECTS      := crow cpp-httplib drogon
RUST_PROJECTS := axum actix-web rocket

# Every project across both lists, for the aggregate debug/release/clean targets.
ALL_PROJECTS := $(PROJECTS) $(RUST_PROJECTS)

.PHONY: all debug release clean clean-all help compile-commands

help:
	@echo "Targets:"
	@echo "  make <name>-debug      Debug build for one project"
	@echo "  make <name>-release    Release build for one project"
	@echo "  make <name>-clean      Remove a project's build artifacts"
	@echo "  make debug | release   Build every project in that configuration"
	@echo "  make clean             Remove every build directory"
	@echo "  make clean-all         Remove all build dirs (cpp build*/ and rust/target)"
	@echo "  make compile-commands  Configure the global build -> build/compile_commands.json"
	@echo ""
	@echo "Exclude endpoints at compile time (all on by default), e.g.:"
	@echo "  make crow-release EXTRA_CMAKE_ARGS=\"-DENDPOINT_BIGFILE=OFF\"       # C++"
	@echo "  make axum-release EXTRA_CARGO_ARGS=\"--no-default-features --features echo\"  # Rust"
	@echo ""
	@echo "C++ projects:  $(PROJECTS)"
	@echo "Rust projects: $(RUST_PROJECTS)"

# Configure the aggregate project (cpp/CMakeLists.txt) to generate a single
# build/compile_commands.json covering every implementation, for editor
# IntelliSense / clangd. Configures only; it does not compile anything.
compile-commands:
	cmake -S cpp -B build $(CMAKE_FLAGS) -DCMAKE_BUILD_TYPE=Debug

# Aggregate targets across all projects (C++ and Rust).
all: release
debug:   $(addsuffix -debug,$(ALL_PROJECTS))
release: $(addsuffix -release,$(ALL_PROJECTS))
clean:   $(addsuffix -clean,$(ALL_PROJECTS))
	rm -rf build

# Remove every C++ build* directory anywhere in the tree (the root build/ and
# each cpp/<name>/build-debug, build-release) plus the Rust target directory.
clean-all:
	find . -type d -name 'build*' -prune -exec rm -rf {} +
	rm -rf rust/target

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

# Generate <name>-debug / <name>-release / <name>-clean for each Rust project.
# All three crates live in the rust/ Cargo workspace; the package name is
# <name>-server (e.g. axum -> axum-server).
define RUST_template
.PHONY: $(1)-debug $(1)-release $(1)-clean

$(1)-debug:
	cd rust && cargo build -p $(1)-server $(EXTRA_CARGO_ARGS)

$(1)-release:
	cd rust && cargo build -p $(1)-server --release $(EXTRA_CARGO_ARGS)

$(1)-clean:
	cd rust && cargo clean -p $(1)-server
endef

$(foreach p,$(RUST_PROJECTS),$(eval $(call RUST_template,$(p))))
