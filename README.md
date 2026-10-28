# rn-ship

EAS-style CI/CD for **bare React Native** apps: a fastlane plugin plus GitHub composite actions. No Expo account; it runs on your own CI, GitHub-hosted runners or a self-hosted Mac.

> Work in progress: v0.1 is being extracted from the [Splitify](https://splitify.cc) release pipeline.

## Actions so far

| Action | What it does |
|---|---|
| `rn_ship_next_version` | Next version + build number from the store state. The store is the source of truth; a live version gets a patch bump; `monotonic_build` keeps Play versionCodes counting. |
| `rn_ship_push_release` | Rebases the bump commit onto the remote branch, tags it and pushes both with `--atomic`, retrying when the other platform pushed first. |

## Development

```sh
bundle install
bundle exec rspec
```

## License

MIT
