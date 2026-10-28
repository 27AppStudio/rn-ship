# Changelog

## Unreleased

- `rn_ship_store_state`: reads TestFlight / App Store or Google Play for a flavor and returns the inputs of `rn_ship_next_version`. "Nothing live" is `nil` while API failures still raise; a new app has no build 0; Play's edit is always aborted.
- `rn_ship_config`: loads and validates `rn-ship.yml` (flavors → scheme/configuration/bundle id, Gradle flavor/package, branch, env file, tags). Every problem is reported with its key path; credential fields hold env var names and are never echoed back.
- `rn_ship_next_version`: next version + build number from store state (TestFlight / Play), with Play's monotonic versionCode.
- `rn_ship_push_release`: rebase, tag and atomically push the version bump, retrying when the other platform pushed first.
