#!/usr/bin/env bash
#
# Clean sanitiser build + conformance test for one server implementation.
#
# Performs a from-scratch build of cpp/<project> with AddressSanitizer and
# UndefinedBehaviorSanitizer enabled (clang), starts the server on the given
# port, and runs the generic interface test (scripts/test/run_tests.sh) against
# it.
# The build halts on the first sanitiser error, and the server is shut down
# with SIGINT so it returns from its listen loop cleanly and LeakSanitizer's
# end-of-run leak check fires.
#
# Usage:
#   scripts/test/run_sanitiser_test.sh <project> <binary> <port>
#
#     <project>  Implementation directory under cpp/ (e.g. crow, cpp-httplib).
#     <binary>   Name of the executable CMake builds (e.g. crow_server).
#     <port>     Port the server listens on (passed via the PORT env var).
#
#   VCPKG_ROOT   Path to a vcpkg checkout (default: $HOME/.vcpkg/vcpkg).
#   CXX          C++ compiler (default: clang++).
#
# Exit status: 0 if the build succeeds, every test passes, and the server
# exits with no sanitiser findings; non-zero otherwise.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <project> <binary> <port>" >&2
    exit 2
fi

PROJECT="$1"
BINARY="$2"
PORT="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_DIR="$REPO_ROOT/cpp/$PROJECT"
BUILD_DIR="$PROJECT_DIR/build-asan"

VCPKG_ROOT="${VCPKG_ROOT:-$HOME/.vcpkg/vcpkg}"
TOOLCHAIN="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"

# This project builds exclusively with clang.
CXX="${CXX:-clang++}"

ADDR="http://localhost:$PORT"
SERVER_LOG="$BUILD_DIR/server.out"
SANITISER_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "error: no such project: cpp/$PROJECT" >&2
    exit 2
fi
if [ ! -f "$TOOLCHAIN" ]; then
    echo "error: vcpkg toolchain not found at $TOOLCHAIN" >&2
    echo "       set VCPKG_ROOT to your vcpkg checkout" >&2
    exit 2
fi

# --- Clean build with sanitisers --------------------------------------------

echo "==> Clean build of $PROJECT with ASan + UBSan"
rm -rf "$BUILD_DIR"
cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_CXX_FLAGS="$SANITISER_FLAGS"
cmake --build "$BUILD_DIR"

# --- Start the server --------------------------------------------------------

# Sanitiser runtime options: stop on the first error so it surfaces clearly.
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:abort_on_error=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1:abort_on_error=1"

echo "==> Starting server on port $PORT"
PORT="$PORT" "$BUILD_DIR/$BINARY" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
    # Best-effort: only if the server is still around (it may have crashed).
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -INT "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Wait for the server to accept connections (or die early).
echo "==> Waiting for server to come up"
for _ in $(seq 1 50); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "error: server exited during startup" >&2
        cat "$SERVER_LOG" >&2
        exit 1
    fi
    if curl --silent --output /dev/null --max-time 1 "$ADDR/log"; then
        break
    fi
    sleep 0.2
done

# --- Run the generic conformance test ---------------------------------------

echo "==> Running interface tests against $ADDR"
test_status=0
"$SCRIPT_DIR/run_tests.sh" "$ADDR" || test_status=$?

# --- Shut the server down and check for sanitiser findings -------------------

echo "==> Stopping server"
trap - EXIT
kill -INT "$SERVER_PID" 2>/dev/null || true
server_status=0
wait "$SERVER_PID" || server_status=$?

echo "-----------------------------------------"
if [ "$server_status" -ne 0 ]; then
    echo "Sanitiser/server reported a problem (exit $server_status):"
    cat "$SERVER_LOG"
fi

if [ "$test_status" -eq 0 ] && [ "$server_status" -eq 0 ]; then
    echo "All tests passed, no sanitiser findings."
    exit 0
fi
echo "FAILED (tests exit=$test_status, server exit=$server_status)"
exit 1
