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

# Projects that have a CMake build (add new implementations here).
PROJECTS := crow cpp-httplib drogon

.PHONY: all debug release clean help

help:
	@echo "Targets:"
	@echo "  make <name>-debug      Debug build   -> cpp/<name>/build-debug"
	@echo "  make <name>-release    Release build -> cpp/<name>/build-release"
	@echo "  make <name>-clean      Remove a project's build directories"
	@echo "  make debug | release   Build every project in that configuration"
	@echo "  make clean             Remove every build directory"
	@echo ""
	@echo "Projects: $(PROJECTS)"

# Aggregate targets across all projects.
all: release
debug:   $(addsuffix -debug,$(PROJECTS))
release: $(addsuffix -release,$(PROJECTS))
clean:   $(addsuffix -clean,$(PROJECTS))

# Generate <name>-debug / <name>-release / <name>-clean for each project.
define PROJECT_template
.PHONY: $(1)-debug $(1)-release $(1)-clean

$(1)-debug:
	cmake -S cpp/$(1) -B cpp/$(1)/build-debug \
		-DCMAKE_TOOLCHAIN_FILE="$(TOOLCHAIN)" \
		-DCMAKE_BUILD_TYPE=Debug
	cmake --build cpp/$(1)/build-debug

$(1)-release:
	cmake -S cpp/$(1) -B cpp/$(1)/build-release \
		-DCMAKE_TOOLCHAIN_FILE="$(TOOLCHAIN)" \
		-DCMAKE_BUILD_TYPE=Release
	cmake --build cpp/$(1)/build-release

$(1)-clean:
	rm -rf cpp/$(1)/build-debug cpp/$(1)/build-release
endef

$(foreach p,$(PROJECTS),$(eval $(call PROJECT_template,$(p))))
