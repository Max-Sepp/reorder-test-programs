#!/usr/bin/env bash
#
# Clean-build every server implementation in BOTH debug and release, and collect
# the binaries into a single top-level `test_binaries/` directory, split into
# `test_binaries/debug/` and `test_binaries/release/`.
#
# Builds the full set the project can produce, all endpoints on (defaults):
#
#   C++   (CMake + vcpkg)   crow_server, httplib_server, drogon_server
#   Rust  (Cargo workspace) axum_server, actix_server, rocket_server
#   Scala (scala-cli/native) http4s_server
#
# Each toolchain is cleaned first so this is a from-scratch build.
#
# Usage:
#   scripts/build_test_binaries.sh
#
# Environment:
#   VCPKG_ROOT   vcpkg checkout for the C++ builds (default: ~/.vcpkg/vcpkg,
#                as per the Makefile).
#   SCALA_CLI    scala-cli executable (default: scala-cli on PATH).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/test_binaries"

SCALA_CLI="${SCALA_CLI:-scala-cli}"

cd "$REPO_ROOT"

if ! command -v "$SCALA_CLI" >/dev/null 2>&1; then
    echo "error: scala-cli not found (set SCALA_CLI to override)" >&2
    exit 1
fi

# --- Clean every toolchain's build output ------------------------------------

echo "==> Cleaning previous build artifacts"
make clean-all                       # cpp build*/ dirs + rust/target
rm -rf scala/http4s/.scala-build     # scala-cli / Scala Native cache

# --- Build C++ and Rust in both configurations -------------------------------

# `make debug` / `make release` build every C++ (CMake) and Rust (Cargo) project
# in that configuration.
echo "==> Building C++ and Rust debug binaries"
make debug
echo "==> Building C++ and Rust release binaries"
make release

# --- Build the Scala Native binary in both configurations --------------------

# server.scala pins `nativeMode "debug"`; --native-mode overrides it per build.
# --power: `package` is a restricted command; --force: overwrite the output.
echo "==> Building Scala Native (http4s) debug binary"
"$SCALA_CLI" --power package --native --native-mode debug \
    "$REPO_ROOT/scala/http4s" \
    -o "$REPO_ROOT/scala/http4s/http4s_server-debug" --force
echo "==> Building Scala Native (http4s) release binary"
"$SCALA_CLI" --power package --native --native-mode release-fast \
    "$REPO_ROOT/scala/http4s" \
    -o "$REPO_ROOT/scala/http4s/http4s_server-release" --force

# --- Collect the binaries ----------------------------------------------------

echo "==> Collecting binaries into $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/debug" "$OUT_DIR/release"

# label -> "<debug path>|<release path>" of the built executables.
binaries=(
    "crow_server:cpp/crow/build-debug/crow_server|cpp/crow/build-release/crow_server"
    "httplib_server:cpp/cpp-httplib/build-debug/httplib_server|cpp/cpp-httplib/build-release/httplib_server"
    "drogon_server:cpp/drogon/build-debug/drogon_server|cpp/drogon/build-release/drogon_server"
    "axum_server:rust/target/debug/axum_server|rust/target/release/axum_server"
    "actix_server:rust/target/debug/actix_server|rust/target/release/actix_server"
    "rocket_server:rust/target/debug/rocket_server|rust/target/release/rocket_server"
    "http4s_server:scala/http4s/http4s_server-debug|scala/http4s/http4s_server-release"
)

missing=0
for entry in "${binaries[@]}"; do
    label="${entry%%:*}"
    paths="${entry#*:}"
    debug_path="${paths%%|*}"
    release_path="${paths#*|}"

    for cfg in debug release; do
        if [ "$cfg" = debug ]; then path="$debug_path"; else path="$release_path"; fi
        if [ -x "$REPO_ROOT/$path" ]; then
            cp "$REPO_ROOT/$path" "$OUT_DIR/$cfg/$label"
            echo "    + $cfg/$label"
        else
            echo "    ! missing: $path" >&2
            missing=1
        fi
    done
done

if [ "$missing" -ne 0 ]; then
    echo "error: one or more binaries were not built" >&2
    exit 1
fi

echo "-----------------------------------------"
echo "Done. Binaries in $OUT_DIR:"
ls -la "$OUT_DIR/debug" "$OUT_DIR/release"
