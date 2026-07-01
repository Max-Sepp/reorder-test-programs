#!/usr/bin/env bash
# Measure the initial startup time and request latency of a Rust server
# implementation.
#
# Waits for the server to return a successful response to a request, then
# measures the time taken for the server to start up and respond to the
# request.
#
# Output is a CSV of just the memory access output, no other information, i.e. it
# has been cleaned up to only contain the memory accesses recorded by valgrind.
# Columns are "type,address,size" where type is I (instruction fetch), L (load),
# S (store) or M (modify), address is hex and size is bytes. The CSV goes to
# stdout by default (progress goes to stderr, so the stream stays clean and
# pipeable), or to the given file.
#
# The server is run under valgrind's lackey tool (--trace-mem=yes), which
# records every memory reference from the first instruction, so the trace
# covers startup and the first request.
#
# Args:
#   $1: The path to the server binary to run.
#   $2: Memory access CSV output file (optional; defaults to stdout).
#
# Env:
#   PORT: Port the server listens on (default 8080). Set this to avoid
#         clashing with an already-running server.
#
# Example:
#   # Build the Axum server, then trace its startup + first request.
#   ( cd rust && cargo build -p axum-server )
#   PORT=8090 scripts/analyse/measure_initial_startup_and_request.sh rust/target/debug/axum_server > axum.memtrace.csv
#
#   # axum.memtrace.csv now holds only the memory accesses, e.g.:
#   #   type,address,size
#   #   I,042e1e40,3
#   #   S,1ffefff488,8

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <server-binary> [memory-access-output-file]" >&2
    exit 2
fi

BINARY="$1"
# Where the cleaned-up memory access trace ends up. Defaults to stdout.
OUTPUT="${2:-}"

if [ ! -x "$BINARY" ]; then
    echo "error: server binary not found or not executable: $BINARY" >&2
    exit 2
fi

# Port the server listens on; the servers read this from PORT. Overridable so
# this can run against any implementation without clashing with a live server.
PORT="${PORT:-8080}"
ADDR="http://localhost:$PORT"

# Raw valgrind output, including its own banner lines; cleaned up at the end.
RAW="$(mktemp)"

# --- Startup the server under valgrind --------------------------------------

# Lackey's --trace-mem=yes emits every instruction fetch and load/store/modify
# (the "memory references"), one per line, from the very first instruction --
# so the trace covers startup. --log-file keeps that stream in $RAW instead of
# interleaving it with our own output.
echo "==> Starting server under valgrind on port $PORT" >&2
PORT="$PORT" valgrind \
    --tool=lackey \
    --trace-mem=yes \
    --log-file="$RAW" \
    "$BINARY" >/dev/null 2>&1 &
SERVER_PID=$!

cleanup() {
    # Best-effort: only if the server is still around (it may have crashed).
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$RAW"
}
trap cleanup EXIT

# --- Wait for the server to start up and respond to a request ---------------

# Under valgrind startup is slow, so allow a generous number of attempts. Each
# curl is itself the request we are measuring the response to.
echo "==> Waiting for server to come up and answer a request" >&2
start_ns="$(date +%s%N)"
ready=0
for _ in $(seq 1 600); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "error: server exited during startup" >&2
        cat "$RAW" >&2
        exit 1
    fi
    if curl --silent --output /dev/null --max-time 1 "$ADDR/log"; then
        ready=1
        break
    fi
    sleep 0.2
done

if [ "$ready" -ne 1 ]; then
    echo "error: server did not respond in time" >&2
    exit 1
fi

end_ns="$(date +%s%N)"
echo "==> Startup + first request took $(( (end_ns - start_ns) / 1000000 )) ms" >&2

# --- Stop recording memory references ---------------------------------------

# Terminating the server stops valgrind, which flushes and finishes the trace.
echo "==> Stopping recording" >&2
kill "$SERVER_PID" 2>/dev/null || true

# --- Clean up the server process --------------------------------------------

trap - EXIT
wait "$SERVER_PID" 2>/dev/null || true

# --- Clean up the memory access output file ---------------------------------

# Lackey prints trace lines raw ("I  addr,size", " L addr,size", " S ...",
# " M ..."); valgrind's own status lines are prefixed with "==<pid>==". Keep
# only the trace lines and reshape each into a CSV row: the access type (I =
# instruction fetch, L = load, S = store, M = modify), the hex address, and the
# size in bytes.
echo "==> Writing cleaned memory access trace${OUTPUT:+ to $OUTPUT}" >&2
clean_trace() {
    awk '
        BEGIN { print "type,address,size" }
        /^ ?[ILSM] / { split($2, a, ","); printf "%s,%s,%s\n", $1, a[1], a[2] }
    ' "$RAW"
}
if [ -n "$OUTPUT" ]; then clean_trace > "$OUTPUT"; else clean_trace; fi

rm -f "$RAW"
echo "==> Done" >&2
