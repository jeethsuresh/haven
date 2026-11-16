#!/usr/bin/env bash
set -euo pipefail

# This test is for a disposable native Linux runner with Docker and sudo.
image="$1"
scratch="$(mktemp -d)"
backend_pid=
proxy_pid=
cleanup() {
    docker rm -f haven-test-a haven-test-b >/dev/null 2>&1 || true
    if [[ -n "$backend_pid" ]]; then kill "$backend_pid" 2>/dev/null || true; fi
    if [[ -n "$proxy_pid" ]]; then kill "$proxy_pid" 2>/dev/null || true; fi
    sudo rm -rf -- "$scratch"
}
trap cleanup EXIT

mkdir -p "$scratch"/{state-a,state-b,repo-a/Files,repo-b,catalog,Fixture.photoslibrary/database}
python3 - "$scratch/Fixture.photoslibrary/database/Photos.sqlite" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript("""
        CREATE TABLE Z_METADATA(Z_UUID TEXT);
        INSERT INTO Z_METADATA VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff');
        CREATE TABLE ZASSET(Z_PK INTEGER, ZUUID TEXT, ZFILENAME TEXT,
          ZDIRECTORY TEXT, ZKIND INTEGER);
        CREATE TABLE ZGENERICALBUM(Z_PK INTEGER, ZUUID TEXT, ZTITLE TEXT, ZKIND INTEGER);
    """)
PY
tar -czf "$scratch/library.tar.gz" -C "$scratch" Fixture.photoslibrary
digest="$(sha256sum "$scratch/library.tar.gz" | cut -d ' ' -f 1)"
name="$digest.photoslibrary.tar.gz"
mv "$scratch/library.tar.gz" "$scratch/repo-a/Files/$name"

(cd backend && CGO_ENABLED=0 go build -o "$scratch/haven" .)
CGO_ENABLED=0 go build -o "$scratch/probe" deploy/truenas/smoke/probe.go
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=127.0.0.1' \
    -addext 'subjectAltName=IP:127.0.0.1' -addext 'basicConstraints=critical,CA:TRUE' \
    -keyout "$scratch/ca.key" -out "$scratch/ca.crt" >/dev/null 2>&1
HAVEN_DEV=1 HAVEN_LISTEN=127.0.0.1:45981 HAVEN_APP_URL=https://127.0.0.1:45982 \
    HAVEN_DATA="$scratch/catalog" "$scratch/haven" >"$scratch/backend.log" 2>&1 &
backend_pid=$!
"$scratch/probe" serve "$scratch" >"$scratch/tls.log" 2>&1 &
proxy_pid=$!
curl --silent --show-error --fail --retry 5 --retry-connrefused --max-time 2 \
    --cacert "$scratch/ca.crt" https://127.0.0.1:45982/healthz >/dev/null
"$scratch/probe" seed "$scratch"
sudo chown -R 568:568 "$scratch"/{state-a,state-b,repo-a,repo-b}

for side in a b; do
    docker run --detach --name "haven-test-$side" --network host --read-only \
        --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:rw,mode=1777 \
        -v "$scratch/state-$side:/state" -v "$scratch/repo-$side:/repository" \
        -v "$scratch/ca.crt:/etc/ssl/certs/ca-certificates.crt:ro" \
        -e HAVEN_BACKEND_URL=https://127.0.0.1:45982 -e "HAVEN_DEVICE_NAME=Test sink $side" "$image"
done

for attempt in $(seq 1 40); do
    if sudo "$scratch/probe" check "$scratch" "$name" > "$scratch/result.log" 2>&1; then
        cat "$scratch/result.log"
        exit 0
    fi
    for side in a b; do
        if [[ "$(docker inspect "haven-test-$side" --format '{{.State.Running}}')" != true ]]; then
            docker logs "haven-test-$side"
            exit 1
        fi
    done
    sleep 3
done
cat "$scratch/result.log"
docker logs haven-test-a
docker logs haven-test-b
exit 1
