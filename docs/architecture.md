# Architecture and protocol v1

Roles are capabilities: `viewer` is always present; Android can also be `source`;
desktop can additionally be `source` and/or `sink`. The user's “sync” is modeled
as a sink participating in bidirectional revision replication. A web browser is
a viewer. Every role uses the same virtual namespace.

```mermaid
flowchart LR
  IAM[Gravitas IAM] -->|PKCE and session checks| C[Haven control service]
  P[Android source and viewer] -->|manifests and thumbnails| C
  C <-->|SDP and ICE only| D[Desktop sink and viewer]
  P ==>|original bytes over direct WebRTC| D
  D <-->|direct revision replication| D2[Another desktop sink]
  C -->|catalog and thumbnails| W[Web viewer]
  S[STUN only] -. address discovery .-> P
  S -. address discovery .-> D
```

## Catalog

`Device` has an account, roles, platform, heartbeat, and revocation flag.
`Asset` has a stable ID, kind, normalized virtual path, MIME, capture time, and
immutable revision descriptors. A revision has an ID, byte size, SHA-256, author
device, and timestamp. `Replica` records the asset/revision/device and receipt
time. `Transfer` binds an exact asset/revision to an authorized source and sink.

Publishing includes the base revision. A stale base creates a separate asset
with `conflict_of` and a disambiguated filename. Case-insensitive collisions are
also preserved as named copies. Path validation excludes traversal, absolute
paths, alternate Windows streams, reserved filenames, and the private `.haven`
namespace. Source publication advertises available bytes; a sink receipt adds a
verified replica. Current-head sink receipts drive the viewer's stored count.

## Control endpoints

All `/api` operations except configuration and login require a Haven session.
Web uses a host-only HttpOnly cookie; native uses an opaque bearer stored in OS
secure storage. The backend stores only its hash plus an encrypted IAM session
envelope. Mutations require `X-Haven-CSRF: 1` and, when supplied, an exact origin.
Sessions each bind to one device. Revoking it denies its subsequent API requests.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/api/config` | STUN URLs, namespaces, development flag, frame size |
| GET | `/api/me` | Current account and bound device |
| GET/POST | `/api/devices` | List devices; register/update the calling device |
| POST | `/api/devices/heartbeat` | Update presence |
| DELETE | `/api/devices/{id}` | Revoke an owned device |
| GET/POST | `/api/assets` | Catalog; publish a descriptor and base revision |
| PUT/GET | `/api/assets/{id}/thumbnail` | Bounded PNG/JPEG in, re-encoded JPEG out |
| GET | `/api/transfers` | Account transfer plans |
| POST | `/api/transfers/{id}` | Status or sink-only hash receipt |
| POST/GET | `/api/signals` | Authorized offer/answer/ICE; cursor-based polling |
| POST | `/api/auth/native/start` | Begin challenge-bound native browser login |
| POST | `/api/auth/native/poll` | Redeem a completed approval once |
| POST | `/api/auth/logout` | Revoke the local session, even during an IAM outage |

JSON control bodies are limited to 32 KiB. Thumbnail input is limited to 128 KiB
and 512×512 pixels, decoded and re-encoded to remove ancillary metadata. SDP/ICE
is capped at 24 KiB per envelope, 256 signals per transfer, 4,096 total, and a
10-minute TTL. There is no original-byte route. Signaling is transient; catalog,
sessions, revisions, and receipts survive restarts.

## Byte protocol

One ordered reliable data channel named `haven-v1` carries one exact revision:

1. Sender: `start { revision, sha256, size }`.
2. Receiver validates the descriptor and returns `ready { offset }` from its
   persisted `.part` file.
3. Sender sends binary frames up to 16 KiB. At most 256 KiB remains unacknowledged.
   Receiver appends/flushed bytes at the expected offset and sends `ack { offset }`.
4. After all bytes are acknowledged, sender sends `done`.
5. Receiver verifies full length and SHA-256, retains an existing old original,
   commits the partial to the visible filesystem, saves its local index, and
   posts a receipt to the backend. Only then does it return `complete`.

Corrupt partials are discarded. Incomplete partials remain for another attempt.
An unexpected offset or unsent local edit blocks replacement. Peer timeouts
leave the transfer waiting and retry at a bounded cadence. Source files are
never removed by this process. Initial sink synchronization is per-file; there
is no claim of an atomic whole-library snapshot.

## Extension points

`Media/`, `Files/`, `Structured/Contacts/`, and `Structured/Notes/` are independent
roots. Structured adapters serialize versioned payloads conforming to
`schemas/structured-v1.schema.json`, then use the same revision/hash/replica byte
pipeline. The backend stores descriptors, not contacts or notes bodies. Field
merging, CRDTs, tombstones, and schema upgrades can be added above this layer
without routing originals through the coordinator.

The snapshot store is intentionally single-process. Its updates mutate a private
clone and atomically replace an fsynced owner-private snapshot; failed writes
leave the active state unchanged. Thumbnails are separately private on disk.
For scale, replace this with transactional storage behind the same API, not a
second uncoordinated JSON writer.
