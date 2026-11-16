#!/bin/sh
set -eu
umask 077
set -- xvfb-run -a "--server-args=-screen 0 800x600x24 -nolisten tcp" /app/haven
if [ "${HAVEN_USE_MEDIA_MOUNT:-0}" = 1 ]; then
  set -- flock -n /media/.haven-sink.lock "$@"
fi
exec flock -n /state/.haven-sink.lock flock -n /repository/.haven-sink.lock "$@"
