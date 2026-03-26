#!/usr/bin/env bash
set -euo pipefail

PORT=9198

exec trunk serve --port "$PORT" "$@"
