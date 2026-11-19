# Haven sink on TrueNAS

This custom app signs in to Haven and registers as a Linux **Sink**. Other
Haven devices send files directly over WebRTC. The existing receiver resumes
partial writes under `.haven` and verifies SHA-256 before committing the file.
The container has no web UI or published TCP port. TrueNAS storage is supplied
by the host-path mounts, and removing the container leaves the datasets.

## Build and install

From the Haven repository, build the image for the NAS architecture. For a
typical x86-64 NAS, use a Linux x86-64 Docker builder and run:

```sh
docker build -f deploy/truenas/Dockerfile -t localhost/haven-truenas-sink:0.2.0 client
docker save -o haven-truenas-sink.tar localhost/haven-truenas-sink:0.2.0
```

Copy the image archive to TrueNAS and load it with `docker load -i` from
the TrueNAS shell. Use a Docker-based TrueNAS release with **Apps → Install via
YAML**. Create a dedicated state dataset and a repository dataset. Grant numeric
user/group 568 the necessary read, write and traverse permissions on those two
datasets. Keep the state dataset private because it contains device sign-in
state. Edit the two host paths in `compose.yaml` and use that file in the YAML
installer. Files land under `Media`, `Files` and `Structured` in the repository.
The service uses the host network so peers can reach its ICE candidates.

To put media on a second dataset, also bind mount that dataset to `/media`
with `create_host_path: false` and add `HAVEN_USE_MEDIA_MOUNT: "1"`. Give the
same UID/GID access there. This overrides the `Media` folder; other files stay in
the repository.

## Pair and transfer

When the app log asks for browser approval, open the TrueNAS app shell and
run `cat /state/approval-url`. Open that URL in your browser and approve the
device with the same Gravitas account used on your Mac. The URL is temporary.
Choose the existing sink if you're upgrading and still using its original
datasets. This keeps its device ID and transfer history. Choose **New sink**
for a fresh install. After pairing, the app keeps its own transfer credential
on the private state dataset. It reconnects after a restart and continues
working when your browser session expires or you sign out of Gravitas.

Use **Devices** in Haven to revoke the sink if the NAS or its credential is
lost. Keep the state mount when upgrading. To pair again after revocation,
stop the app and remove the saved `.session-*` files from its dedicated
**state** dataset, then restart and approve the new request. The repository
and media datasets are independent of the credential.

Version 0.2.0 requires a Haven server with unattended sink pairing. Older
servers report that they are waiting for support until the server is updated.

On the Mac, configure a writable Haven repository and enable **Source** (or
**Sink**). Use the Apple Photos import to send browseable files or **Back Up
Photos Library** to send a complete restorable archive. Wait for Haven to show
the TrueNAS replica as stored. Restore the archive from a Mac onto a directly
attached APFS or Mac OS Extended volume before opening it in Apple Photos.
