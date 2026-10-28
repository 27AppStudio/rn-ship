#!/usr/bin/env bash
# Writes $SECRET_CONTENT to a file only the runner user can read.
#
# The value arrives through an environment variable, never inside the script text: a
# `${{ secrets.X }}` written into a `run:` block is pasted into the shell source, where `$`,
# backticks and quotes in the secret are expanded or break the script.
#
# Usage: SECRET_CONTENT=... write-secret.sh <path> [--base64]
set -euo pipefail

dest=${1:?usage: write-secret.sh <path> [--base64]}
mode=${2:-}

if [ -z "${SECRET_CONTENT:-}" ]; then
  echo "::error::Nothing to write to $dest: the secret is empty or not set"
  exit 1
fi

mkdir -p "$(dirname "$dest")"
umask 077
if [ "$mode" = "--base64" ]; then
  # Secrets pasted from `base64` output often carry line breaks.
  printf '%s' "$SECRET_CONTENT" | tr -d '[:space:]' | base64 --decode > "$dest"
else
  printf '%s\n' "$SECRET_CONTENT" > "$dest"
fi
# umask only applies to new files; an existing one keeps its mode otherwise.
chmod 600 "$dest"
