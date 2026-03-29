#!/bin/bash
set -euo pipefail

echo "=== Leihs Database Migration ==="
echo "Waiting for PostgreSQL..."

# Wait for database to be available
until pg_isready -h "${DB_HOST:-leihs-db}" -p "${DB_PORT:-5432}" -U "${DB_USER:-leihs}" -d "${DB_NAME:-leihs}" -q; do
  echo "  PostgreSQL not ready, waiting..."
  sleep 2
done
echo "PostgreSQL is ready."

cd /build/leihs/database

# Set required env vars
export SECRET_KEY_BASE="${LEIHS_MASTER_SECRET:-$(openssl rand -hex 32)}"
export RAILS_ENV=production
export RAILS_LOG_LEVEL=WARN

echo "=== Running database migrations ==="
bundle exec rake db:migrate

echo "=== Applying seed data ==="
SEEDS_FILE="/build/leihs/database/db/seeds.sql"
if [ -f "$SEEDS_FILE" ]; then
  psql -h "${DB_HOST:-leihs-db}" -p "${DB_PORT:-5432}" -U "${DB_USER:-leihs}" -d "${DB_NAME:-leihs}" \
    -f "$SEEDS_FILE" 2>&1 | grep -v "duplicate key" | grep -v "already exists" || true
  echo "Seed data applied (duplicates ignored)."
else
  echo "WARNING: seeds.sql not found at $SEEDS_FILE"
fi

echo "=== Database migration finished ==="
