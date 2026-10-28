# Security

[README](../README.md) · [Architecture](architecture.md) · [Configuration](configuration.md) · [Security](security.md) · [Testing](testing.md)

| Threat | Mitigation | Status |
|---|---|---|
| Secret committed in config | The config only accepts env var *names* (`/\A[A-Z_][A-Z0-9_]*\z/`). Anything else fails validation. | Shipped |
| Secret echoed into CI logs | Errors on credential fields never print the value (only its type, for non-strings). | Shipped |
| Secret expanded by the shell | No `run:` block in the actions contains a `${{ }}` expression (a spec enforces it): secrets reach the shell through `env:` and files are written with `printf`, so `$`, backticks and quotes in a value are never expanded. | Shipped |
| CI creating or revoking certificates | fastlane's `setup_ci` already makes match read-only on hosted runners. `rn_ship_ci_signing` sets it on every path, including self-hosted Macs where `setup_ci` doesn't run. | Shipped |
| Taking over a developer's login keychain (self-hosted Mac) | A dedicated non-default keychain with a random password, first in the search list, deleted in `after_all` / `error`; one left by a crashed run is replaced. Archives go to `$RUNNER_TEMP`. | Shipped |
| Signing settings drifting in the checked-in project | `rn_ship_ios_signing` rewrites them from `rn-ship.yml` on every build, after the preflight proves every target exists (`update_code_signing_settings` skips unknown targets silently). | Shipped |
| A stale `/tmp/envfile` swapping the config | react-native-config's Xcode script reads it before `ENVFILE`. The iOS preflight refuses to build while it exists. | Shipped |
| Credentials left on a persistent runner | Secrets are written mode 600 under `$RUNNER_TEMP`, never `~/.ssh`. Cleanup with `if: always()` removes keys, env files, the generated `.env`, `ios/tmp.xcconfig` and react-native-config's `GeneratedDotEnv.m`, and restores rather than deletes files git tracks. | Shipped |
| Env values cached into `node_modules` | The `setup` action saves its cache right after installing, before any build writes the env file's values into `node_modules`. | Shipped |
| A bump commit starting another deploy | Bump commits carry `[skip ci]`, in case they're pushed with a token that triggers workflows. | Shipped |
| Expired API key read as "nothing live" | The live version is read through Spaceship, where "nothing live" is `nil` and an API failure raises. | Shipped |
| Shipping a debug-signed AAB | The first AAB permanently enrolls its key on Play, and React Native's template signs release builds with the public debug key when the upload key is missing. The build refuses to start without the upload key, and the AAB's certificate must match the upload key's exactly, so it isn't enough to merely differ from the debug key. | Shipped |
| Store password in the process list | keytool gets the password through `-storepass:env`, never as an argument `ps` would show. | Shipped |
| Shipping the wrong env file | react-native-config silently falls back to `.env` when the requested file is missing, and the build still succeeds. The preflight requires the flavor's file and sets `ENVFILE` to its absolute path. | Shipped |
| Build-only keys inside the app | react-native-config compiles *every* key of the env file into the app. Keep CI credentials out of `.env.*` files and in CI env vars. | documented |
