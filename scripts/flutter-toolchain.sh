#!/usr/bin/env bash
set -euo pipefail
sdk="$RUNNER_TEMP/haven-flutter"
git init "$sdk"
git -C "$sdk" remote add origin https://github.com/flutter/flutter.git
git -C "$sdk" fetch --depth 1 origin refs/tags/3.47.7:refs/tags/3.47.7
git -C "$sdk" checkout --detach abaf9c523780a608bd46686fd5e53740a07077f8
test "$(git -C "$sdk" rev-parse HEAD)" = abaf9c523780a608bd46686fd5e53740a07077f8
echo "$sdk/bin" >> "$GITHUB_PATH"
