#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f client/build/web/index.html ]]; then
  (cd client && flutter pub get && flutter build web --release)
fi
cd backend
export HAVEN_DEV=1
export HAVEN_LISTEN=127.0.0.1:8090
export HAVEN_APP_URL=http://127.0.0.1:8090
export HAVEN_DATA=../.local/backend
exec go run .
