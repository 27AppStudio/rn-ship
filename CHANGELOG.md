# Changelog

## Unreleased

- Template: Play beta releases are named after the version; promotion passes `track_promote_release_status` (supply ignores `release_status` there). Deploy actions take `ruby-version`.
- Deploy actions: `fastlane-dir` for per-platform fastlane folders (`ios/fastlane`, `android/fastlane`); `ios-deploy` takes the .p8 key as is or base64-encoded; `pod install` retries with `--repo-update` only when it fails; self-hosted runners keep gems in the tool cache (a pinned `vendor/bundle` becomes a link).
- Composite actions `setup`, `ios-deploy`, `android-deploy`, `notify` and `examples/deploy.yml`. Secrets reach the shell only through `env:` (enforced by a spec), are written mode 600 and removed with `if: always()`; credentials are exported under the env var names from `rn-ship.yml`; the node_modules cache is saved before any build.
- `templates/`: reference Fastfile (`ios`/`android` `beta` and `release`), Pluginfile and Gemfile.
- `rn_ship_xcode_version`; `bump:` on `rn_ship_next_version`; a version write returns `files:`, exactly what to commit.
- `rn_ship_ios_preflight`, `rn_ship_ci_signing`, `rn_ship_ci_signing_cleanup`, `rn_ship_ios_signing`: iOS signing on CI. Targets, configuration and shared scheme checked against the real project before anything runs; a stale `/tmp/envfile` refused; a dedicated non-default keychain on self-hosted Macs; match read-only on every CI path; signing and bundle ids written from `rn-ship.yml` for the app and every extension.
- `rn_ship_android_preflight`, `rn_ship_verify_aab`, `rn_ship_gradle_version`: Android guards. No build without the upload key; no upload unless the AAB is signed with exactly that key (keytool reads the password from an env var); `ENVFILE` pinned to the flavor's file as an absolute path; one literal `versionCode`/`versionName` in `defaultConfig`, per-flavor overrides refused.
- `rn_ship_store_state`: reads TestFlight / App Store or Google Play for a flavor and returns the inputs of `rn_ship_next_version`. "Nothing live" is `nil` while API failures still raise; a new app has no build 0; Play's edit is always aborted.
- `rn_ship_config`: loads and validates `rn-ship.yml` (flavors → scheme/configuration/bundle id, Gradle flavor/package, branch, env file, tags). Every problem is reported with its key path; credential fields hold env var names and are never echoed back.
- `rn_ship_next_version`: next version + build number from store state (TestFlight / Play), with Play's monotonic versionCode.
- `rn_ship_push_release`: rebase, tag and atomically push the version bump, retrying when the other platform pushed first.
