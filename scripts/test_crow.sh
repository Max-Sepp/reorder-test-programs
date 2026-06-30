#!/usr/bin/env bash
#
# Clean sanitiser build + conformance test for the Crow server (port 8080).
# Thin wrapper around run_sanitiser_test.sh; see that script for details.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_sanitiser_test.sh" crow crow_server 8080
