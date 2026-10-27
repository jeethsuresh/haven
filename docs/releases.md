# Continuous distribution

Source: https://github.com/jeethsuresh/haven. The `Haven web and Android` workflow runs on every push to `main`; PRs execute the same checks without production or signing credentials.

## Android

Permanent application ID: `cool.gravitas.haven`. Permanent certificate SHA-256:

`3c01375ebd40c543f9d6d1a6c1aeb18c689188eee35341a3b1ba3b89a397c085`

The main-only `android-release` environment holds the four encrypted `RELEASE_*` signing secrets. A protected local backup of Haven’s own key was created during setup. Never replace this key with another app’s key. The build verifies the keystore and final APK against the tracked certificate pin before publication and removes transient signing material even after a failure.

Every workflow run allocates `MAJOR.MINOR.<GITHUB_RUN_NUMBER>` and uses that number as Android `versionCode`. The source `client/pubspec.yaml` selects the major/minor series; `scripts/ci-version.py` prepares the exact generated pubspec and matching changelog in CI. A run is reproducible with `python3 scripts/ci-version.py --run-number N`. Do not rename/reset the publishing workflow without migrating its increasing build-number sequence.

A successful main run first deploys and verifies the matching backend, then publishes `Haven-vVERSION-android.apk`, `SHA256SUMS`, `release-manifest.json`, and `changelog.json` in a stable GitHub release. The signed APK embeds `https://haven.gravitas.cool` as its backend. Existing tags/releases are never overwritten; replaying a published run skips publication. Private Store pins the package and certificate, validates each APK/changelog, and ingests release webhook events with polling as recovery.

Update tracked `changelog.json` whenever user-visible behavior changes. Its version fields are a source template; CI substitutes the run’s exact release version and code. This intentionally publishes every main push without requiring a manual version bump.

## Deployment

`.gravitas/deploy.json` selects the existing Gravitas cluster, Haven namespace, `haven.gravitas.cool`, one replica with Recreate, a retained 5 GiB volume, and the `haven-runtime` session-encryption secret. The main-only `gravitas` environment holds a namespace-scoped kubeconfig and a read-only key for the pinned shared deployment tooling. Cluster administrator access is never copied to CI. `/healthz` must return 200 and `/api/me` must return 401 with no-store headers for an unauthenticated HTTPS request.

## Desktop

The manual `desktop-artifacts.yml` workflow builds Linux, Windows and macOS bundles. Its HTTPS backend-origin input is required. These are unsigned build artifacts, not published signed installers. Desktop signing/notarization and automatic GitHub desktop releases remain a separate step.
