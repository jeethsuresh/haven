# Distribution scaffold

The permanent Android application ID is `cool.gravitas.haven`. The initial
version is `0.1.0+1`. No release key has been created or borrowed from another
app. A release build must use Haven's own protected signing identity; preserve
it for every future Private Store update.

## Android

Use `flutter build apk --debug` only for local testing. Add a release signing
configuration backed by environment/CI secrets, verify the APK with `apksigner`,
record its certificate SHA-256 and file SHA-256, and test an install/upgrade on a
physical device before publishing. `android-release.example.json` documents the
release metadata to adapt to the Private Store's actual ingestion contract; it
is not an uploaded catalog entry. The existing native account broker uses
app-specific bindings, so Haven must be registered deliberately before adding
that login path. The browser PKCE path works independently of that broker.

## Desktop

The manual `desktop-artifacts.yml` workflow builds native bundles on Linux,
Windows, and macOS and uploads them as CI artifacts. Its backend origin is a
required input. It does not publish a release or claim that unsigned bundles
are installers. Linux needs the listed GTK, Secret Service, PulseAudio and
WebRTC build dependencies. Windows needs the Visual Studio desktop toolchain.
macOS needs Xcode plus signing/notarization for distribution.

Once the device flow is verified against a real HTTPS deployment, create a
GitHub repository, configure CI signing, package/sign the native bundles, and
publish a draft GitHub release containing installers and SHA-256 checksums.
Only verified signed Android releases should then be ingested by the Private
Store. Neither channel has been published by this local-scaffold task.
