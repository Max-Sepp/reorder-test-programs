#!/usr/bin/env bash
#
# Clean build + conformance test for one Scala Native server implementation.
#
# Builds a scala-cli sources path into a native executable, starts the server on
# the given port, and runs the generic interface test (scripts/test/run_tests.sh)
# against it. The server is shut down with SIGTERM once testing completes.
#
# This is the Scala Native counterpart of run_cargo_test.sh. scala-cli links via
# clang, so the runner needs clang plus the GC/unwind dev libraries the chosen
# garbage collector requires (boehm -> libgc-dev, immix/commix -> libunwind-dev).
#
# Usage:
#   scripts/test/run_scala_native_test.sh <source> <binary> <port>
#
#     <source>   scala-cli sources path (a .scala file or a directory of them),
#                relative to the repo root, e.g. scala/http4s.
#     <binary>   Name for the built executable (e.g. http4s_server).
#     <port>     Port the server listens on (passed via the PORT env var).
#
#   SCALA_CLI    scala-cli executable to use (default: scala-cli on PATH).
#
# Exit status: 0 if the build succeeds and every test passes; non-zero
# otherwise.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <source> <binary> <port>" >&2
    exit 2
fi

SOURCE="$1"
BINARY="$2"
PORT="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_PATH="$REPO_ROOT/$SOURCE"

SCALA_CLI="${SCALA_CLI:-scala-cli}"
ADDR="http://localhost:$PORT"

if [ ! -e "$SRC_PATH" ]; then
    echo "error: no scala sources at $SRC_PATH" >&2
    exit 2
fi
if ! command -v "$SCALA_CLI" >/dev/null 2>&1; then
    echo "error: scala-cli not found (set SCALA_CLI to override)" >&2
    exit 2
fi

# Build into a scratch dir so the working tree stays clean; removed on exit.
BUILD_DIR="$(mktemp -d)"
BINARY_PATH="$BUILD_DIR/$BINARY"
SERVER_LOG="$BUILD_DIR/$BINARY.out"

SERVER_PID=""
cleanup() {
    # Best-effort: only if the server is still around (it may have crashed).
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# --- Build ------------------------------------------------------------------

echo "==> Building $SOURCE with scala-cli (native)"
# --power: `package` is a restricted command; --force: overwrite the output.
"$SCALA_CLI" --power package --native "$SRC_PATH" -o "$BINARY_PATH" --force

if [ ! -x "$BINARY_PATH" ]; then
    echo "error: built binary not found at $BINARY_PATH" >&2
    exit 1
fi

# --- Start the server --------------------------------------------------------

echo "==> Starting server on port $PORT"
PORT="$PORT" "$BINARY_PATH" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

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

# --- Shut the server down ----------------------------------------------------

echo "==> Stopping server"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo "-----------------------------------------"
if [ "$test_status" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
echo "FAILED (tests exit=$test_status)"
cat "$SERVER_LOG"
exit 1
