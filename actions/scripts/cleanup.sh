#!/usr/bin/env bash
# Removes the credentials a deploy wrote, and the files react-native-config generated from the
# env file, so nothing outlives the job on a self-hosted runner. Runs with `if: always()`, so
# missing files and empty arguments are fine. A file git tracks is restored, not deleted.
#
# Usage: cleanup.sh <path>...
set -uo pipefail

for path in "$@"; do
  [ -n "$path" ] || continue
  if git ls-files --error-unmatch -- "$path" > /dev/null 2>&1; then
    git checkout -- "$path"
  else
    rm -f -- "$path"
  fi
done
