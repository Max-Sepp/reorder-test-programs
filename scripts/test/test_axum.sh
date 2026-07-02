#!/usr/bin/env bash
#
# Clean build + conformance test for the Axum server (port 8083). Thin wrapper
# around run_cargo_test.sh; see that script for details.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_cargo_test.sh" axum-server axum_server 8083
