#!/usr/bin/env zsh
set -euo pipefail

for service in local.flow local.study-task-overlay; do
  security delete-generic-password \
    -s "$service" \
    -a google-oauth-token \
    2>/dev/null || true
done

echo "Flow Google auth token reset"
