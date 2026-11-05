# Agent instructions

Merging to main automatically deploys and publishes to customers. Work on a branch, review the final diff and run relevant analysis, unit, integration and native smoke checks with the pinned production toolchains. All required CI must pass on the exact final PR commit before merge. Do not disable checks to ship a failure.

Preserve `.github/workflows/gravitas.yml` main-only deployment, all test/build prerequisites, immutable image digest, namespace-scoped Gravitas environment, rollout checks and public HTTPS verification. Android retains its permanent package/certificate and automatic workflow-run version sequence; see [docs/releases.md](docs/releases.md). Never replace signing keys or overwrite published releases.

Before merging changes intended for desktop users, increase desktop version/versionCode and user-facing changes in `desktop-release.config.json`. Preserve native package/launch/plugin/storage checks, deployment's dependency on `desktop-verify`, and main-only publication after verified deployment. Desktop versions are independent of Android. Verify public packages and their discovery/changelogs in Private Store; see [DESKTOP_RELEASES.md](DESKTOP_RELEASES.md).

## Android back and forward navigation

All current and future Gravitas Android touch interfaces must follow [ANDROID_NAVIGATION.md](ANDROID_NAVIGATION.md): left-edge Back and right-edge Forward on Android 14+, bounded destination history, safe restoration without repeating actions, keyboard/modal precedence, and account isolation. New screens must integrate the shared history and include relevant regression coverage. Keep legacy Back behavior on older Android versions.
