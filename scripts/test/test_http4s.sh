#!/usr/bin/env bash
#
# Clean build + conformance test for the http4s Scala Native server (port 8086).
# Thin wrapper around run_scala_native_test.sh; see that script for details.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_scala_native_test.sh" scala/http4s http4s_server 8086
