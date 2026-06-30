#!/usr/bin/env bash
#
# Generic conformance test for the shared test-program HTTP interface.
#
# Exercises every route a server must implement and checks the responses.
# The server under test is named on the command line, so this script works
# against any implementation (Crow, cpp-httplib, drogon, ...) regardless of
# language or framework.
#
# Usage:
#   scripts/run_tests.sh <server-address>
#
#   <server-address>  Base URL of a running server, e.g. http://localhost:8080
#                     or just localhost:8080 (http:// is assumed). A trailing
#                     slash is fine.
#
# Exit status: 0 if every test passes, 1 otherwise.

set -u

# --- Arguments --------------------------------------------------------------

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <server-address>" >&2
    echo "  e.g. $0 http://localhost:8080" >&2
    exit 2
fi

ADDR="$1"
ADDR="${ADDR%/}"                       # drop trailing slash
case "$ADDR" in
    http://*|https://*) ;;             # keep as-is
    *) ADDR="http://$ADDR" ;;          # default to http://
esac

# Expected fixture sizes from the shared interface (assets/smallfile is 1 KiB,
# assets/bigfile is 1 MiB). Override via the environment if the fixtures change.
SMALLFILE_SIZE="${SMALLFILE_SIZE:-1024}"
BIGFILE_SIZE="${BIGFILE_SIZE:-1048576}"

CURL="curl --silent --show-error --fail-with-body --max-time 30"

PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "Testing server at $ADDR"

# --- POST /echo -------------------------------------------------------------

payload="hello, $(date +%s)-$RANDOM"
got="$($CURL --data-binary "$payload" "$ADDR/echo")"
if [ "$got" = "$payload" ]; then
    pass "POST /echo returns the request body"
else
    fail "POST /echo: expected '$payload', got '$got'"
fi

# --- POST /log then GET /log ------------------------------------------------

marker="test-marker-$(date +%s)-$RANDOM"
if $CURL --data-binary "$marker" "$ADDR/log" >/dev/null; then
    log="$($CURL "$ADDR/log")"
    if printf '%s' "$log" | grep -qF "$marker"; then
        pass "POST /log appends and GET /log returns it"
    else
        fail "GET /log did not contain the appended marker '$marker'"
    fi
else
    fail "POST /log request failed"
fi

# --- GET /smallfile and GET /bigfile ----------------------------------------

check_size() {
    local route="$1" expected="$2"
    local actual
    actual="$($CURL "$ADDR/$route" | wc -c)"
    if [ "$actual" = "$expected" ]; then
        pass "GET /$route returns $expected bytes"
    else
        fail "GET /$route: expected $expected bytes, got $actual"
    fi
}

check_size smallfile "$SMALLFILE_SIZE"
check_size bigfile "$BIGFILE_SIZE"

# --- Summary ----------------------------------------------------------------

echo "-----------------------------------------"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
