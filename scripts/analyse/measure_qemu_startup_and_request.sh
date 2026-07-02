#!/usr/bin/env bash
# QEMU counterpart of measure_valgrind_startup_and_request.sh: trace a server
# binary's startup + first request and emit the memory-access CSV the analysis
# pipeline consumes (columns "type,address,size"; I = instruction fetch, L =
# load, S = store; address hex, size bytes).
#
# Why QEMU instead of valgrind: valgrind's synthetic client stack cannot survive
# Scala Native's startup stack-overflow-guard probe (tryGrowStack), so lackey
# segfaults before the server ever serves. QEMU user-mode emulates the program
# faithfully (delivering the guest's own signals), so it runs cleanly. A small
# TCG plugin (scripts/analyse/qemu_memtrace_plugin.c) writes the CSV directly.
#
# Tracing every instruction + memory access of a managed-runtime startup is slow
# and voluminous, so the readiness budget is generous and the CSV is written
# straight to the output file (no huge intermediate text log).
#
# Args:
#   $1: server binary to run.
#   $2: output CSV file (optional; defaults to stdout).
#
# Env:
#   PORT      Port the server listens on (default 8080).
#   METHOD    Request method whose first response we trace (default GET).
#   ENDPOINT  Request endpoint (default /log).
#   BODY      Request body for non-GET methods (default empty).
#   QEMU      qemu-x86_64 to use (default: the built third_party/qemu one).
#   PLUGIN    memtrace plugin .so (default: built from the .c next to the qemu
#             build if missing).

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <server-binary> [output-csv]" >&2
    exit 2
fi

BINARY="$1"
OUTPUT="${2:-}"

if [ ! -x "$BINARY" ]; then
    echo "error: server binary not found or not executable: $BINARY" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PORT="${PORT:-8080}"
ADDR="http://localhost:$PORT"
METHOD="${METHOD:-GET}"
ENDPOINT="${ENDPOINT:-/log}"
BODY="${BODY:-}"

QEMU="${QEMU:-$REPO_ROOT/third_party/qemu/build/qemu-x86_64}"
PLUGIN="${PLUGIN:-$REPO_ROOT/third_party/qemu/build/libmemtrace.so}"
PLUGIN_SRC="$SCRIPT_DIR/qemu_memtrace_plugin.c"

if [ ! -x "$QEMU" ]; then
    echo "error: qemu not found at $QEMU (build third_party/qemu first)" >&2
    exit 2
fi

# Build the memtrace plugin on demand (or if the source is newer than the .so).
if [ ! -f "$PLUGIN" ] || [ "$PLUGIN_SRC" -nt "$PLUGIN" ]; then
    echo "==> Building memtrace plugin -> $PLUGIN" >&2
    gcc -O2 -shared -fPIC -I "$REPO_ROOT/third_party/qemu/include/qemu" \
        $(pkg-config --cflags glib-2.0) "$PLUGIN_SRC" \
        -o "$PLUGIN" $(pkg-config --libs glib-2.0)
fi

# curl args for the traced request, reused by every readiness attempt.
REQUEST_ARGS=(--silent --output /dev/null --max-time 30 -X "$METHOD")
if [ "$METHOD" != "GET" ] && [ "$METHOD" != "HEAD" ]; then
    REQUEST_ARGS+=(--data-binary "$BODY")
fi

# Write the CSV straight to the destination. If no output file was given, use a
# temp file and stream it to stdout at the end (guest stdout/stderr are sent to
# /dev/null so they never mix with the plugin's CSV on the -D log fd).
if [ -n "$OUTPUT" ]; then CSV="$OUTPUT"; else CSV="$(mktemp)"; fi

# TRACE_MEM=0 records only instruction fetches (I rows) -- a smaller, faster
# trace for the ordering/page analyses, which ignore L/S rows. Default: full.
PLUGIN_SPEC="$PLUGIN"
if [ "${TRACE_MEM:-1}" = 0 ]; then PLUGIN_SPEC="$PLUGIN,nomem"; fi

echo "==> Tracing startup + $METHOD $ENDPOINT of $BINARY under QEMU on port $PORT" >&2
PORT="$PORT" "$QEMU" -plugin "$PLUGIN_SPEC" -d plugin -D "$CSV" "$BINARY" >/dev/null 2>&1 &
QEMU_PID=$!

cleanup() {
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    [ -z "$OUTPUT" ] && rm -f "$CSV"
}
trap cleanup EXIT

# Wait for the server to answer a request. QEMU + full tracing is slow, so allow
# a long budget (up to ~15 min). The first successful curl is the request we are
# measuring the response to.
echo "==> Waiting for server to come up and answer a $METHOD $ENDPOINT request" >&2
start_ns="$(date +%s%N)"
ready=0
for _ in $(seq 1 1800); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "error: server exited during startup" >&2
        exit 1
    fi
    if curl "${REQUEST_ARGS[@]}" "$ADDR$ENDPOINT"; then
        ready=1
        break
    fi
    sleep 0.5
done

if [ "$ready" -ne 1 ]; then
    echo "error: server did not respond in time" >&2
    exit 1
fi

end_ns="$(date +%s%N)"
echo "==> Startup + first request took $(( (end_ns - start_ns) / 1000000 )) ms (traced)" >&2

# Terminating the guest lets QEMU finish and flush the plugin trace.
echo "==> Stopping recording" >&2
kill "$QEMU_PID" 2>/dev/null || true
trap - EXIT
wait "$QEMU_PID" 2>/dev/null || true

lines="$(wc -l < "$CSV")"
echo "==> Wrote $lines trace rows${OUTPUT:+ to $OUTPUT}" >&2
if [ -z "$OUTPUT" ]; then cat "$CSV"; rm -f "$CSV"; fi
echo "==> Done" >&2
