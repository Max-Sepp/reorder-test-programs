#!/usr/bin/env bash
#
# Clean build + conformance test for one Rust server implementation.
#
# Builds a package from the rust/ Cargo workspace, starts the server on the
# given port, and runs the generic interface test (scripts/test/run_tests.sh)
# against it. The server is shut down with SIGTERM once testing completes.
#
# This is the Rust counterpart of run_sanitiser_test.sh, but it does not enable
# AddressSanitizer/UBSan: the Rust servers contain no `unsafe` code of their
# own, so the conformance test against the shared interface is the correctness
# check here.
#
# Usage:
#   scripts/test/run_cargo_test.sh <package> <binary> <port>
#
#     <package>  Cargo package in the rust/ workspace (e.g. axum-server).
#     <binary>   Name of the built executable (e.g. axum_server).
#     <port>     Port the server listens on (passed via the PORT env var).
#
#   CARGO_BUILD_ARGS  Extra args forwarded to `cargo build` (e.g.
#                     "--no-default-features --features echo,log").
#
# Exit status: 0 if the build succeeds and every test passes; non-zero
# otherwise.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <package> <binary> <port>" >&2
    exit 2
fi

PACKAGE="$1"
BINARY="$2"
PORT="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUST_DIR="$REPO_ROOT/rust"

ADDR="http://localhost:$PORT"
SERVER_LOG="$RUST_DIR/target/$BINARY.out"

if [ ! -d "$RUST_DIR" ]; then
    echo "error: no rust/ workspace at $RUST_DIR" >&2
    exit 2
fi

# --- Build ------------------------------------------------------------------

echo "==> Building $PACKAGE"
# shellcheck disable=SC2086  # CARGO_BUILD_ARGS is intentionally word-split.
( cd "$RUST_DIR" && cargo build -p "$PACKAGE" ${CARGO_BUILD_ARGS:-} )

BINARY_PATH="$RUST_DIR/target/debug/$BINARY"
if [ ! -x "$BINARY_PATH" ]; then
    echo "error: built binary not found at $BINARY_PATH" >&2
    exit 1
fi

# --- Start the server --------------------------------------------------------

echo "==> Starting server on port $PORT"
PORT="$PORT" "$BINARY_PATH" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
    # Best-effort: only if the server is still around (it may have crashed).
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
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

# --- Shut the server down ----------------------------------------------------

echo "==> Stopping server"
trap - EXIT
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

echo "-----------------------------------------"
if [ "$test_status" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
echo "FAILED (tests exit=$test_status)"
cat "$SERVER_LOG"
exit 1
