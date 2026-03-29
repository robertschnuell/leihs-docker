#!/bin/bash
set -euo pipefail

# Read master secret from volume if available
MASTER_SECRET_FILE="/leihs/secret/master_secret.txt"
if [ -f "$MASTER_SECRET_FILE" ]; then
  export LEIHS_MASTER_SECRET=$(cat "$MASTER_SECRET_FILE")
fi

echo "Starting leihs-${SERVICE_NAME}..."

# The Clojure services read their configuration from environment variables:
#   HTTP_PORT  - HTTP listen port (via :http-port key)
#   DB_HOST    - PostgreSQL host (via :db-host key)
#   DB_PORT    - PostgreSQL port (via :db-port key)
#   DB_NAME    - Database name (via :db-name key)
#   DB_USER    - Database user (via :db-user key)
#   DB_PASSWORD - Database password (via :db-password key)
# No CLI args needed — env vars are picked up automatically by the shared-clj config.

exec java \
  ${JAVA_OPTS:--Xmx512m} \
  -Duser.dir=/leihs \
  -jar /leihs/service.jar \
  run
