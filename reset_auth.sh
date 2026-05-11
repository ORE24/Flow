#!/usr/bin/env zsh
set -euo pipefail

security delete-generic-password \
  -s local.flow \
  -a google-oauth-token \
  2>/dev/null || true

echo "Flow Google auth token reset"
