#!/usr/bin/env bash
# Posts a one-line deploy status to a Discord- or Slack-compatible webhook. The payload carries
# both `content` (Discord) and `text` (Slack); each ignores the other.
#
# Usage: WEBHOOK_URL=... notify.sh <status> <title>
#        NOTIFY_PRINT=1 prints the payload instead of sending it.
set -euo pipefail

status=${1:?usage: notify.sh <status> <title>}
title=${2:?usage: notify.sh <status> <title>}

if [ -z "${WEBHOOK_URL:-}" ] && [ -z "${NOTIFY_PRINT:-}" ]; then
  echo "No webhook configured, skipping the notification"
  exit 0
fi

run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
message="[$status] $title on ${GITHUB_REF_NAME:-?} by ${GITHUB_ACTOR:-?}: $run_url"
payload=$(MESSAGE="$message" python3 -c 'import json, os; m = os.environ["MESSAGE"]; print(json.dumps({"content": m, "text": m}))')

if [ -n "${NOTIFY_PRINT:-}" ]; then
  printf '%s\n' "$payload"
  exit 0
fi

# A failed notification must never fail the deploy it reports on.
curl --silent --show-error --fail --max-time 15 -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null ||
  echo "::warning::Could not post the notification"
