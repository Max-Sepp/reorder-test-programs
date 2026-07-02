#!/usr/bin/env bash
#
# Clean sanitiser build + conformance test for the cpp-httplib server
# (port 8081). Thin wrapper around run_sanitiser_test.sh; see that script for
# details.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_sanitiser_test.sh" cpp-httplib httplib_server 8081
