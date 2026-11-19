#!/bin/sh
set -eu
umask 077
if [ "${1:-}" != run ]; then
  set -- /bin/sh /app/entrypoint.sh run
  if [ "${HAVEN_USE_MEDIA_MOUNT:-0}" = 1 ]; then
    set -- flock -n /media/.haven-sink.lock "$@"
  fi
  exec flock -n /state/.haven-sink.lock flock -n /repository/.haven-sink.lock "$@"
fi

# WebRTC initializes an audio device for its peer factory even for file transfers.
# Supply a private virtual device without passing through host audio hardware.
export XDG_RUNTIME_DIR=/tmp/haven-runtime
export PULSE_SERVER=unix:/tmp/haven-runtime/pulse/native
mkdir -p "$XDG_RUNTIME_DIR/pulse"
pulseaudio -n -F /app/pulse.pa --daemonize=yes --exit-idle-time=-1 --disable-shm=yes
exec xvfb-run -a "--server-args=-screen 0 800x600x24 -nolisten tcp" /app/haven
