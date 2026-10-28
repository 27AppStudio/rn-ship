#!/usr/bin/env bash
# Installs the gems on a self-hosted runner into its tool cache, so compiled gems survive the
# workspace wipe every checkout does. A path pinned in the repo's .bundle/config (vendor/bundle,
# say) wins over BUNDLE_PATH, so that folder becomes a link into the cache instead.
#
# Usage: bundle-install.sh   (in the repo root, on a self-hosted runner)
set -euo pipefail

cache="$RUNNER_TOOL_CACHE/rn-ship-bundle/${GITHUB_REPOSITORY//\//-}"
mkdir -p "$cache"

pinned=$(bundle config get path --parseable 2> /dev/null | sed -n 's/^path=//p')
if [ -z "$pinned" ]; then
  echo "BUNDLE_PATH=$cache" >> "$GITHUB_ENV"
  export BUNDLE_PATH="$cache"
elif [ ! -e "$pinned" ]; then
  mkdir -p "$(dirname "$pinned")"
  ln -s "$cache" "$pinned"
  # A .gitignore entry like /vendor/bundle/ only matches a directory, not this link.
  echo "/$pinned" >> .git/info/exclude
fi
bundle install --jobs 4
