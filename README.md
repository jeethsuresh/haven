# Haven

Your media, on your devices. An early media backup app with a shared Flutter client for Android sources, desktop sinks, and web viewers, plus a Go control service. The `main` pipeline deploys the service at https://haven.gravitas.cool and publishes a signed Android release for [Private Store](https://apps.gravitas.cool/apps/haven).

## Run locally

Requirements: Go 1.25+, Flutter 3.47.7 / Dart 3.13.5 (the verified toolchain), and
the platform build tools for your native target. The backend uses only Go's
standard library. Flutter dependencies are pinned in `client/pubspec.lock`.

```bash
chmod +x scripts/*.sh
./scripts/dev.sh
```

Open **http://127.0.0.1:8090**, then choose **Enter local development workspace**.
This creates a fresh viewer session in a shared local test account. It never
impersonates a Gravitas account. Development authentication is refused unless
the server binds a loopback address. The local catalog is in `.local/backend/`.

Run the native desktop app in another terminal:

```bash
cd client
flutter pub get
flutter run -d linux  # or macos / windows on the matching OS
```

Sign in to the same local workspace, open **Devices → Configure this device**,
choose a repository folder, enable **Sink**, and save. Originals appear in:

```text
Repository/
  Media/2026/10/photo.jpg
  Files/...
  Structured/Contacts/...
  Structured/Notes/...
  .haven/partials/    # resumable incoming bytes
  .haven/history/     # previous originals retained on replacement
```

You can delegate `Media/` to another selected folder. Set folders before enabling
sink mode. To try a source without Android, enable **Source** on a second desktop
instance and press **Scan now** to pick files. Use separate application data
directories or OS users for two independent desktop identities.

For an attached Android device or emulator:

```bash
adb reverse tcp:8090 tcp:8090
cd client
flutter run -d YOUR_ANDROID_DEVICE
```

Enter the local workspace, enable **Source**, and approve gallery access. Android
scans permitted MediaStore photos, videos, and audio. Selected-media access is
respected. Gallery discovery and transfer run while the app is open. Scans run
every minute, with **Scan now** for an immediate scan. The phone never deletes
gallery originals. For separate networks, use an HTTPS backend and your own STUN
server rather than loopback development mode.

## What is implemented

| Component | Included behavior |
| --- | --- |
| All clients | Media grid, photo/video/audio filters, search, file tree, device roles, transfer list, revision/hash details |
| Android source | Runtime gallery permissions, MediaStore discovery, bounded thumbnail generation, streaming content URI reads |
| Desktop sink | Selected repository and optional media root, periodic discovery of edits, direct receiving, disk resume, SHA-256 verification, retained previous versions |
| Peer transfer | WebRTC data channels; 16 KiB frames; a bounded 256 KiB sending window; persisted resume offset; retries when a direct route is unavailable |
| Backend | Account-scoped devices/catalog/replicas, versioned manifests, automatic source-to-sink jobs, bounded SDP/ICE signaling, persisted device status reports |
| Identity | Gravitas custom PKCE, host-only web sessions, native browser approval/polling bound to a client challenge, central family revalidation before every protected request |
| Other data | `file`, `contact`, and `note` kinds, dedicated roots, and versioned structured schemas; editors and native contacts/notes adapters are future work |

An item is **Stored** only after at least one active sink reports that it verified
the expected SHA-256 and committed the file. Metadata and thumbnails alone never
count as a backup. This trusts the sink's receipt; the server does not inspect
original bytes. Device identity and catalog access are bound to the signed-in
Gravitas `(issuer, sub)` account.

Desktop content edits are published as revisions and replicated to other sinks.
If two devices edit the same base revision, Haven retains the second branch as a
named conflict copy. It does not silently select a last writer. Files replaced
by the receiver are retained in `.haven/history/`.

## Gravitas and networking

Production requires HTTPS, a session encryption key, a persistent data volume,
and a pinned Gravitas issuer. Copy `.env.example` to `.env` and fill it locally.
Never commit `.env` or a signing key. Docker builds the pinned Flutter web viewer and Go server from source:

```bash
docker compose up --build
# Optional separate STUN service:
docker compose --profile stun up --build
```

The production pipeline uses the existing Gravitas HTTPS ingress, an app-scoped deployer, and a retained 5 GiB catalog/report volume. For independent hosting, terminate HTTPS at your reverse proxy and forward to the loopback HTTP port.
Set `HAVEN_APP_URL` to the exact public origin. The callback is
`/auth/gravitas/callback`; the login entry point is `/auth/gravitas/start`.
The existing Gravitas protocol needs no OAuth client secret or OIDC registration.
The IAM module was adapted from the local River backend and its tests retained.
Sessions require a fresh login after eight hours, or sooner if Gravitas revokes
the family. Local sign-out remains usable during an IAM outage.

STUN discovers peer addresses; it does **not** relay media. The service coordinates
SDP/ICE over HTTPS, and the optional Coturn sidecar accepts **STUN only**.
`HAVEN_STUN_URLS` accepts only `stun:` URLs, and clients reject relay candidates.
No original-upload endpoint and no TURN fallback exist. With restrictive NAT or
firewalls, a job waits for a direct route; connectivity is not guaranteed.
Use your own directly reachable UDP STUN endpoint in production. See
[WebRTC peer connections](https://webrtc.org/getting-started/peer-connections)
and [Coturn configuration](https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf).

Web viewers use cached thumbnails from browser `localStorage` first. On a cache
miss or revision change, they fetch a bounded thumbnail directly over WebRTC
from an online source or sink. Thumbnail bytes never pass through the backend.
Sources and sinks report pending items and errors every 15 seconds while open;
viewers can read the latest persisted reports even after a device goes offline.

## Scope and next steps

This establishes the architecture and first media flow, not a production release:

- Android background/foreground-service lifecycle, charging/Wi-Fi policies,
  permission recovery, paged gallery discovery, and native Private Store account
  broker integration remain to be added. Browser-based Gravitas login is wired.
- Native contacts/notes adapters and editors are scaffolded. Their payloads use
  the peer byte path; the backend holds only their descriptors.
- Renames and deletions do not propagate as destructive operations. A rename is
  discovered as an additional file; missing source files never delete backups.
  Tombstones, retention/GC policy, and recovery UI need a deliberate next design.
- The catalog uses a private, atomic JSON snapshot with one writer. Run one
  backend instance. SQLite/Postgres migrations, pagination, quotas, and operational
  audit/rate limits are required before a substantial library or public service.
- Active peers recheck account/device authorization via polling every three
  seconds. Native process/background behavior and real cross-network transfer
  have not been verified on physical devices in this scaffold.
- Local originals and thumbnails are not encrypted at rest by Haven. Data-channel
  transport uses DTLS; independently authenticated device keys and protection
  from a compromised signaling server are future work.
- Desktop installer signing/notarization and GitHub desktop releases remain future work. Android publication and web deployment run automatically after the main pipeline passes. See [release notes](docs/releases.md).

## Continuous publication

Every push to `main` runs backend race tests, client tests and analysis, an Android debug build, and a production image build. A successful run deploys the exact image digest and checks public HTTPS before signing and publishing the APK. Release identity is `0.1.<workflow run number>` with that run number as the Android version code; reruns never overwrite a published release. GitHub queues main runs rather than replacing pending publications.

The initial deployment uses Cloudflare’s public `stun:stun.cloudflare.com:3478` for address discovery. Haven never configures TURN or sends original media through that endpoint. Replace `HAVEN_STUN_URLS` with an owned STUN service when desired.

## Validate

```bash
./scripts/check.sh
```

Backend tests cover ownership across restarts, cross-account isolation, device
roles/revocation, signaling authorization, forbidden relay candidates, manifest
validation, direct thumbnail requests, account-scoped device reports, conflict branches, and sink receipts. The retained
IAM tests exercise PKCE, issuer discovery, federation boundaries, and central
revocation. Flutter tests exercise persisted resume, corruption rejection,
offset bounds, prior-version retention, unsent edit protection, delegated media
folders, and path/symlink rejection. See [architecture](docs/architecture.md)
and [verification](docs/verification.md) for the tested boundaries.
