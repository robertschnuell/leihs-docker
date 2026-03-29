#!/bin/bash
set -euo pipefail

# Read master secret from volume if available
MASTER_SECRET_FILE="/leihs/secret/master_secret.txt"
if [ -f "$MASTER_SECRET_FILE" ]; then
  export LEIHS_MASTER_SECRET=$(cat "$MASTER_SECRET_FILE")
  export LEIHS_SECRET="${LEIHS_MASTER_SECRET}"
  export SECRET_KEY_BASE="${LEIHS_MASTER_SECRET}"
fi

echo "Starting leihs-legacy (Rails) on port ${LEIHS_LEGACY_PORT:-3210}..."

cd /leihs/legacy

exec bundle exec puma -C config/puma.rb
