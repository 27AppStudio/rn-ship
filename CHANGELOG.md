# Changelog

## Unreleased

- `rn_ship_next_version`: next version + build number from store state (TestFlight / Play), with Play's monotonic versionCode.
- `rn_ship_push_release`: rebase, tag and atomically push the version bump, retrying when the other platform pushed first.
