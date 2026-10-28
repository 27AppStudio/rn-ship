#!/usr/bin/env bash
# Runs `fastlane <platform> <lane> flavor:<flavor> [bump:<bump>]` from FASTLANE_DIR, the folder
# holding the fastlane/ folder: the repo root, or ios / android when each platform has its own
# (the layout `fastlane init` creates in a React Native project). The caller has exported the
# credentials; on a self-hosted runner this also sets the env var rn-ship.yml names for it.
#
# Usage: SELF_HOSTED=true|false SELF_HOSTED_ENV=<name> [BUMP=...] [FASTLANE_DIR=...] run-lane.sh <platform> <lane> <flavor>
set -euo pipefail

platform=${1:?usage: run-lane.sh <platform> <lane> <flavor>}
lane=${2:?usage: run-lane.sh <platform> <lane> <flavor>}
flavor=${3:?usage: run-lane.sh <platform> <lane> <flavor>}

if [ "${SELF_HOSTED:-}" = true ]; then export "$SELF_HOSTED_ENV=1"; fi
args=("flavor:$flavor")
if [ -n "${BUMP:-}" ]; then args+=("bump:$BUMP"); fi
cd "${FASTLANE_DIR:-.}"
exec bundle exec fastlane "$platform" "$lane" "${args[@]}"
