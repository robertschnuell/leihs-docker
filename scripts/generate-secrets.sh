#!/bin/bash
# =============================================================================
# Generate secrets for leihs Docker Compose deployment
# =============================================================================
# Creates:
#   - .env file with generated passwords and secrets
#   - ES256 key pairs for external authentication
#   - Master secret file for inter-service communication
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYS_DIR="$PROJECT_DIR/keys"
ENV_FILE="$PROJECT_DIR/.env"

echo "=== Leihs Secret Generation ==="
echo ""

# Create keys directory
/bin/mkdir -p "$KEYS_DIR"

# --- Generate ES256 key pair for external authentication bridge ---
if [ ! -f "$KEYS_DIR/oidc-bridge-private.pem" ]; then
  echo "Generating OIDC bridge ES256 key pair..."
  openssl ecparam -name prime256v1 -genkey -noout -out "$KEYS_DIR/oidc-bridge-private.pem"
  openssl ec -in "$KEYS_DIR/oidc-bridge-private.pem" -pubout -out "$KEYS_DIR/oidc-bridge-public.pem"
  echo "  Created: keys/oidc-bridge-private.pem"
  echo "  Created: keys/oidc-bridge-public.pem"
else
  echo "OIDC bridge keys already exist, skipping."
fi

# --- Generate ES256 key pair for leihs ---
if [ ! -f "$KEYS_DIR/leihs-private.pem" ]; then
  echo "Generating leihs ES256 key pair..."
  openssl ecparam -name prime256v1 -genkey -noout -out "$KEYS_DIR/leihs-private.pem"
  openssl ec -in "$KEYS_DIR/leihs-private.pem" -pubout -out "$KEYS_DIR/leihs-public.pem"
  echo "  Created: keys/leihs-private.pem"
  echo "  Created: keys/leihs-public.pem"
else
  echo "leihs keys already exist, skipping."
fi

# --- Generate .env from template ---
if [ ! -f "$ENV_FILE" ]; then
  echo ""
  echo "Generating .env file from template..."

  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  MASTER_SECRET=$(openssl rand -hex 40)

  /bin/cp "$PROJECT_DIR/.env.example" "$ENV_FILE"

  # Replace placeholder values
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/POSTGRES_PASSWORD=CHANGE_ME_GENERATE_WITH_SCRIPT/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" "$ENV_FILE"
    sed -i '' "s/LEIHS_MASTER_SECRET=CHANGE_ME_GENERATE_WITH_SCRIPT/LEIHS_MASTER_SECRET=${MASTER_SECRET}/" "$ENV_FILE"
  else
    sed -i "s/POSTGRES_PASSWORD=CHANGE_ME_GENERATE_WITH_SCRIPT/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" "$ENV_FILE"
    sed -i "s/LEIHS_MASTER_SECRET=CHANGE_ME_GENERATE_WITH_SCRIPT/LEIHS_MASTER_SECRET=${MASTER_SECRET}/" "$ENV_FILE"
  fi

  echo "  Created: .env"
  echo ""
  echo "IMPORTANT: Review .env and configure your deployment settings."
  echo "  See README.md for details on required variables."
else
  echo ""
  echo ".env already exists, skipping. Delete it to regenerate."
fi

# --- Create master secret volume file ---
MASTER_SECRET_DIR="$PROJECT_DIR/data/secret"
/bin/mkdir -p "$MASTER_SECRET_DIR"
if [ ! -f "$MASTER_SECRET_DIR/master_secret.txt" ]; then
  # Read from .env if it exists
  if [ -f "$ENV_FILE" ]; then
    MASTER_SECRET=$(grep '^LEIHS_MASTER_SECRET=' "$ENV_FILE" | cut -d= -f2)
  else
    MASTER_SECRET=$(openssl rand -hex 40)
  fi
  echo -n "$MASTER_SECRET" > "$MASTER_SECRET_DIR/master_secret.txt"
  chmod 600 "$MASTER_SECRET_DIR/master_secret.txt"
  echo "  Created: data/secret/master_secret.txt"
fi

echo ""
echo "=== Public Keys ==="
echo ""
echo "Register these public keys in the leihs admin panel under"
echo "'Authentication Systems' after initial setup:"
echo ""
echo "--- OIDC Bridge Public Key ---"
cat "$KEYS_DIR/oidc-bridge-public.pem"
echo ""
echo "--- leihs Public Key ---"
cat "$KEYS_DIR/leihs-public.pem"
echo ""
echo "=== Done ==="
