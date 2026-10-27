# Local verification — 27 October 2026

Verified with Go 1.25.2 and Flutter 3.47.7 / Dart 3.13.5.

| Check | Result |
| --- | --- |
| `go test ./...` | Passed: 26 backend/IAM test functions |
| `go vet ./...` | Passed |
| Backend binary build | Passed; `-buildvcs=false` used because the task workspace has synthetic read-only Git metadata |
| `flutter analyze` | Passed, no issues |
| `flutter test --no-pub` | Passed: 6 filesystem tests |
| `flutter build web --release --no-pub` | Passed |
| Browser local sign-in | Verified: cookie-backed session, automatic viewer registration, empty catalog |
| Browser media library and device navigation | Verified in the local in-app browser |

The web build emitted a dependency font notice for Cupertino icons. Haven uses
Material icons; no missing icons were observed in its viewer. The Wasm dry run
also succeeded; only the JavaScript web build was used for browser verification.

The test suite checks replica accounting, wrong-hash and wrong-role receipts,
central identity bindings, cross-account boundaries, conflict branches, bounded
thumbnails and signaling, persistence rollback, and failover to a verified sink
when the original phone is offline. Filesystem tests check resume across repository
instances, corruption rejection, offsets, retained history, blocked unsent edits,
delegated media storage, and traversal/symlink rejection.

Go race detection could not run on this host because its C toolchain is absent;
the CI workflow enables it on an Ubuntu runner. Native Android/desktop builds,
gallery permissions on a physical phone, live Gravitas login, actual WebRTC
transfer across physical devices/NATs, Private Store ingestion, and signing or
notarization have not been verified. The included workflows are scaffolding and
have not been run on GitHub. No production service or device was modified.
