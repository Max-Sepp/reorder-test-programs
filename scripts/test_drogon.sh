#!/usr/bin/env bash
#
# Clean sanitiser build + conformance test for the Drogon server (port 8082).
# Thin wrapper around run_sanitiser_test.sh; see that script for details.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_sanitiser_test.sh" drogon drogon_server 8082
