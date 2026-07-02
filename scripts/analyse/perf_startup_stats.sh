#!/usr/bin/env bash
# Measure real hardware/OS counters for a server binary's startup + first
# request, using perf (not valgrind), averaged over several runs.
#
# This is the "validate the simulation against reality" counterpart to the
# valgrind trace: where the trace lets us *simulate* page footprint, this reads
# the actual counters the reordering is meant to move -- page faults, iTLB and
# L1 instruction-cache misses -- plus the peak resident set size (VmHWM) and
# wall-clock startup time.
#
# The binary is exec'd under `perf stat` so counting starts at the very first
# instruction (covering startup). We poll until the server answers one request,
# read its peak RSS from /proc, then SIGINT perf so it stops and reports. That
# whole cycle is repeated -N times and the per-event mean and sample standard
# deviation are printed -- startup counters are noisy, so a single run lies.
#
# Between runs the previous server is fully torn down before the next starts:
# perf is SIGINT'd then SIGKILL'd if it lingers, the workload PID is confirmed
# dead, and we wait for the listening port to be released (a half-dead process
# still holding the port would make the next run fail to bind and exit). Each
# run also refuses to start until the port is free, so a stale server -- from a
# previous invocation or an aborted run -- is caught up front instead of
# silently poisoning the numbers.
#
# Args:
#   $1: Path to the server binary to run.
#
# Options:
#   -n RUNS      Number of repetitions to average (default 5).
#   -e EVENTS    Comma-separated perf event list (default: see EVENTS below).
#   -u PATH      Endpoint to poll for readiness (default /log).
#
# Env:
#   PORT: Port the server listens on (default 8080).
#
# Example:
#   scripts/analyse/perf_startup_stats.sh tmp/actix_experiment_1/actix_server
#   PORT=8096 scripts/analyse/perf_startup_stats.sh -n 10 tmp/actix_experiment_1/actix_optimised_server
#
# Note: hardware counters (iTLB/L1i misses) need a permissive
# /proc/sys/kernel/perf_event_paranoid (<= 2 for these; some events need <= 1).
# Unsupported/uncounted events are simply skipped in the summary.

set -euo pipefail

# perf events to collect. task-clock/cycles/instructions give the baseline; the
# rest are the locality-sensitive ones reordering should improve.
EVENTS="task-clock,cycles,instructions,page-faults,minor-faults,major-faults,iTLB-load-misses,dTLB-load-misses,L1-icache-load-misses,L1-dcache-load-misses,branch-misses"
RUNS=5
ENDPOINT="/log"

usage() {
    echo "usage: $0 [-n runs] [-e events] [-u endpoint] <server-binary>" >&2
    exit 2
}

while getopts "n:e:u:h" opt; do
    case "$opt" in
        n) RUNS="$OPTARG" ;;
        e) EVENTS="$OPTARG" ;;
        u) ENDPOINT="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[ "$#" -ge 1 ] || usage
BINARY="$1"

if [ ! -x "$BINARY" ]; then
    echo "error: server binary not found or not executable: $BINARY" >&2
    exit 2
fi
command -v perf >/dev/null || { echo "error: perf not found" >&2; exit 2; }

PORT="${PORT:-8080}"
ADDR="http://localhost:$PORT"

# How we tell the port is free. ss with a port filter is exact; if ss is missing
# fall back to a fixed settle delay (HAVE_SS=0) so the script still works.
if command -v ss >/dev/null; then HAVE_SS=1; else HAVE_SS=0; fi

# Is anything listening on $PORT right now?
port_in_use() {
    if [ "$HAVE_SS" -eq 1 ]; then
        [ -n "$(ss -Htln "sport = :$PORT" 2>/dev/null)" ]
    else
        return 1  # can't tell without ss; assume free after the settle delay
    fi
}

# Block until the port is released (or time out). Returns non-zero on timeout so
# callers can report a stuck port rather than charging into a failed bind.
wait_port_free() {
    if [ "$HAVE_SS" -eq 0 ]; then sleep 1; return 0; fi
    for _ in $(seq 1 150); do   # up to ~15s
        port_in_use || return 0
        sleep 0.1
    done
    return 1
}

WORKDIR="$(mktemp -d)"
# Per-run perf CSV files (perf -x, output) and one-value-per-line side metrics.
RSS_FILE="$WORKDIR/rss.txt"         # peak RSS (kB) per run
STARTUP_FILE="$WORKDIR/startup.txt" # startup+request wall time (ms) per run
: > "$RSS_FILE"
: > "$STARTUP_FILE"

PERF_PID=""
BIN_PID=""

# Fully stop the current run. Crucially we stop the *workload*, not perf: when
# perf's child exits, perf finalises and flushes its -o stats file and exits on
# its own. Signalling perf directly is wrong -- it then waits on the still-alive
# server (SIGINT to perf just makes it forward SIGTERM and block), and if we
# escalate to SIGKILL on perf it dies without writing any stats.
#
# So: SIGTERM the server, give it a moment, SIGKILL if it ignores that, then
# wait for perf to notice and exit. perf reports counts accumulated up to the
# child's death (startup + first request), which is exactly what we want.
stop_run() {
    # If we never captured the workload PID, try once more so we can stop it
    # (and thus let perf flush) rather than having to SIGKILL perf.
    if [ -z "$BIN_PID" ] && [ -n "$PERF_PID" ]; then
        BIN_PID="$(pgrep -P "$PERF_PID" | head -n1 || true)"
    fi
    if [ -n "$BIN_PID" ] && kill -0 "$BIN_PID" 2>/dev/null; then
        kill -TERM "$BIN_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$BIN_PID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$BIN_PID" 2>/dev/null || true
    fi
    if [ -n "$PERF_PID" ]; then
        # Wait for perf to reap the child and flush stats.
        for _ in $(seq 1 50); do kill -0 "$PERF_PID" 2>/dev/null || break; sleep 0.1; done
        # Last resort so we never hang: if perf is somehow still up (e.g. we
        # never learned the workload PID), SIGKILL it -- stats for this run are
        # then lost, but the loop keeps going.
        kill -KILL "$PERF_PID" 2>/dev/null || true
        wait "$PERF_PID" 2>/dev/null || true
    fi
    PERF_PID=""
    BIN_PID=""
}

cleanup() { stop_run; rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- Run the binary under perf, once per repetition -------------------------

for run in $(seq 1 "$RUNS"); do
    # Refuse to start on a busy port: a leftover server would make this run's
    # bind fail (or, worse, we'd measure the wrong process).
    if port_in_use; then
        echo "==> Port $PORT busy; waiting for it to free before run $run" >&2
        wait_port_free || { echo "error: port $PORT still in use; is another server running?" >&2; exit 1; }
    fi

    statfile="$WORKDIR/run-$run.csv"
    echo "==> Run $run/$RUNS: starting server under perf on port $PORT" >&2

    # -x, : machine-readable CSV. Counting starts at exec, so startup is covered.
    perf stat -x, -o "$statfile" -e "$EVENTS" -- \
        env PORT="$PORT" "$BINARY" >/dev/null 2>&1 &
    PERF_PID=$!

    # Poll until the server answers a request (that curl IS the first request we
    # are measuring), or bail if perf/the workload dies during startup.
    start_ns="$(date +%s%N)"
    ready=0
    for _ in $(seq 1 600); do
        if ! kill -0 "$PERF_PID" 2>/dev/null; then
            echo "error: perf/server exited during startup (run $run) -- port bind clash?" >&2
            exit 1
        fi
        if curl --silent --output /dev/null --max-time 1 "$ADDR$ENDPOINT"; then
            ready=1
            break
        fi
        sleep 0.2
    done
    [ "$ready" -eq 1 ] || { echo "error: server did not respond in time" >&2; exit 1; }

    end_ns="$(date +%s%N)"
    startup_ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "$startup_ms" >> "$STARTUP_FILE"
    echo "==> Run $run: startup + first request took ${startup_ms} ms" >&2

    # perf's direct child (the `env` that execs the binary) is the workload;
    # remember it so stop_run can guarantee it dies, and read its peak RSS now.
    BIN_PID="$(pgrep -P "$PERF_PID" | head -n1 || true)"
    if [ -n "$BIN_PID" ] && [ -r "/proc/$BIN_PID/status" ]; then
        awk '/^VmHWM:/ {print $2}' "/proc/$BIN_PID/status" >> "$RSS_FILE"
    fi

    # Stop perf (flushes stats) and make sure nothing is left holding the port.
    stop_run
    wait_port_free || echo "warning: port $PORT slow to release after run $run" >&2
done

trap - EXIT

# --- Aggregate: mean and sample stddev per event, plus RSS and startup ------

echo >&2
echo "==> Summary over $RUNS run(s) for $(basename "$BINARY")" >&2

# perf -x, rows are: value,unit,event,run-time,pct,metric,metric-unit
# Keep numeric values only ("<not supported>"/"<not counted>" are dropped).
aggregate() {
    awk -F, '
        function commas(x,   s,neg,intpart,frac,n,out) {
            s = sprintf("%.2f", x); n = index(s, ".")
            intpart = substr(s, 1, n - 1); frac = substr(s, n)
            neg = (substr(intpart,1,1) == "-"); if (neg) intpart = substr(intpart,2)
            out = ""
            while (length(intpart) > 3) {
                out = "," substr(intpart, length(intpart)-2) out
                intpart = substr(intpart, 1, length(intpart)-3)
            }
            out = intpart out
            return (neg ? "-" : "") out frac
        }
        $1 ~ /^[0-9.]+$/ && $3 != "" {
            ev = $3
            if (!(ev in seen)) { order[++k] = ev; seen[ev] = 1 }
            n[ev]++; sum[ev] += $1; sumsq[ev] += $1 * $1
        }
        END {
            printf "%-26s %16s %14s %6s\n", "event", "mean", "stddev", "runs"
            printf "%-26s %16s %14s %6s\n", "-----", "----", "------", "----"
            for (i = 1; i <= k; i++) {
                ev = order[i]; c = n[ev]; m = sum[ev] / c
                var = (c > 1) ? (sumsq[ev] - c * m * m) / (c - 1) : 0
                sd = (var > 0) ? sqrt(var) : 0
                printf "%-26s %16s %14s %6d\n", ev, commas(m), commas(sd), c
            }
        }
    ' "$WORKDIR"/run-*.csv
}

# Simple mean/stddev for a single-column file (RSS in kB, startup in ms).
meansd() {
    awk -v label="$1" -v unit="$2" '
        { n++; sum += $1; sumsq += $1 * $1 }
        END {
            if (n == 0) {
                printf "%-26s %16s\n", label, "n/a"
            } else {
                m = sum / n
                var = (n > 1) ? (sumsq - n * m * m) / (n - 1) : 0
                sd = (var > 0) ? sqrt(var) : 0
                printf "%-26s %13.1f %s  (stddev %.1f)\n", label, m, unit, sd
            }
        }
    ' "$3"
}

aggregate
echo
meansd "peak RSS (VmHWM)" "kB" "$RSS_FILE"
meansd "startup + first request" "ms" "$STARTUP_FILE"

rm -rf "$WORKDIR"
echo "==> Done" >&2
