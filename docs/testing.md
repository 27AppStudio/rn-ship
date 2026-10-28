# Testing

[README](../README.md) · [Architecture](architecture.md) · [Configuration](configuration.md) · [Security](security.md) · [Testing](testing.md)

| Level | How | Example |
|---|---|---|
| Pure logic | A table of real scenarios, one example each | 13 resolver scenarios + edge cases, 7 semver bumps |
| Side effects | Against the real thing, locally: temporary bare git repos, a `pre-receive` hook that rejects the first N pushes, a second clone acting as "the other platform" | rebase onto a concurrent push, retry, give up, conflict abort |
| Action wiring | A real lane parsed by `Fastlane::FastFile`, so option parsing, defaults and `lane_context` are exercised | `rn_ship_next_version`, `rn_ship_config`, `rn_ship_store_state` composed with `rn_ship_next_version` |
| Store APIs | Play tracks as recorded-shape doubles through the pure summary; Spaceship and Supply stubbed at their boundary, including "the edit is aborted even when listing fails" | `rn_ship_store_state` |
| Xcode project | A real `.xcodeproj` built with the xcodeproj gem (app + extension, three configurations, shared and user schemes); fastlane's real `update_code_signing_settings` runs against it | `rn_ship_ios_preflight`, `rn_ship_ios_signing` |
| Signing | Real keystores (upload, debug, unrelated) generated with keytool and real bundles signed with jarsigner, once per run. Specs never read the developer's `~/.gradle`. | `rn_ship_verify_aab`: upload, debug, other key, unsigned, wrong password |
| Reference lanes | The template Fastfile run end to end against a real git repo with a bare origin, the Xcode fixture and a Gradle file; only store and compiler calls are stubbed | bump commit holds only version files, CI signing edits never pushed, preflight fails before any commit, debug-signed AAB never uploaded, release branch guard |
| Composite actions | Every `run:` block is shellchecked and must not contain `${{ }}`; the scripts run for real (a secret full of `$`, backticks and quotes is written byte for byte); actionlint checks the example workflow against the actions' inputs; `notify` runs on a real runner in CI | `actions_spec.rb`, CI `actions` job |
| Real stores | Read-only run against Splitify's App Store Connect and Google Play apps, compared with fastlane's built-ins and Splitify's own lanes | manual, before each release |
| Plugin loading | `fastlane run …` from a project with a `Pluginfile`, the way a consumer loads it | manual, before each release |
| Real-world config | Splitify's actual setup as a fixture (irregular schemes, an app extension, custom tags) | `spec/fixtures/splitify.yml` |

CI runs the suite on Ruby 3.1 and 3.4.

## Running the suite

```sh
bundle install
bundle exec rspec
```
