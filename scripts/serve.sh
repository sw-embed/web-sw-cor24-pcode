#!/usr/bin/env bash
set -euo pipefail

PORT=9247

exec trunk serve --port "$PORT" "$@"
