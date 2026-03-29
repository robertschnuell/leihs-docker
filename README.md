# Leihs Docker Compose Deployment

A Docker Compose setup for [leihs](https://github.com/leihs/leihs) — the equipment booking and inventory management system — with OIDC authentication via [Authentik](https://goauthentik.io/).

> **Note:** This is an unofficial, community-maintained Docker deployment. Leihs is officially deployed via Ansible to bare-metal Debian/Ubuntu servers. This project packages all services into Docker containers for easier infrastructure integration.

## Architecture

```
Internet
    │
NPM (Nginx Proxy Manager)    ← SSL termination
    │
    ▼
leihs-reverse-proxy (nginx)  ← Routes by URL path
    │
    ├── /admin/*          → leihs-admin       (Clojure JVM, port 3200)
    ├── /borrow/*         → leihs-borrow      (Clojure JVM, port 3250)
    ├── /my/*             → leihs-my           (Clojure JVM, port 3240)
    ├── /procure/*        → leihs-procure      (Clojure JVM, port 3230)
    ├── /mail/*           → leihs-mail         (Clojure JVM, port 3220)
    ├── /inventory/*      → leihs-inventory    (Clojure JVM, port 3260)
    ├── /authenticators/* → leihs-oidc-bridge  (Python, port 3300)
    └── /*                → leihs-legacy       (Ruby/Rails, port 3210)
    │
    └── PostgreSQL 16 (port 5415)

    Authentik (auth.bitz.rfws.dev) ← OIDC Provider
```

## Services

| Service | Technology | Description |
|---------|-----------|-------------|
| `leihs-legacy` | Ruby on Rails 8.x | Main application (lending, inventory management) |
| `leihs-admin` | Clojure (JVM) | Administration interface |
| `leihs-borrow` | Clojure (JVM) | Borrowing/reservation interface |
| `leihs-my` | Clojure (JVM) | User profile and settings |
| `leihs-procure` | Clojure (JVM) | Procurement module |
| `leihs-mail` | Clojure (JVM) | Email processing service |
| `leihs-inventory` | Clojure (JVM) | Inventory publishing (optional) |
| `leihs-oidc-bridge` | Python (Flask) | Bridges Authentik OIDC ↔ leihs JWT auth |
| `leihs-reverse-proxy` | Nginx | Internal path-based routing |
| `leihs-db` | PostgreSQL 16 | Shared database |
| `leihs-db-migrate` | Ruby + Clojure | Database migration runner (init container) |

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- At least 8 GB RAM available for containers
- Existing Nginx Proxy Manager instance
- Existing Authentik instance with OIDC provider configured

## Quick Start

### 1. Clone and prepare

```bash
git clone <this-repo> leihs-docker
cd leihs-docker
cp .env.example .env
```

### 2. Generate secrets

```bash
./scripts/generate-secrets.sh
```

This generates:
- Database password
- Master secret (shared between all leihs services)
- ES256 key pairs for OIDC bridge ↔ leihs communication

### 3. Configure

Edit `.env` with your values:

```env
LEIHS_EXTERNAL_HOSTNAME=leihs.bitz.rfws.dev
AUTHENTIK_ISSUER_URL=https://auth.bitz.rfws.dev/application/o/leihs/
AUTHENTIK_CLIENT_ID=<from-authentik>
AUTHENTIK_CLIENT_SECRET=<from-authentik>
```

### 4. Build and start

```bash
docker compose up -d --build
```

The first build takes 15-30 minutes (compiling Clojure uberjars and Rails assets).

### 5. Configure NPM

Add a proxy host in Nginx Proxy Manager:
- **Domain:** `leihs.bitz.rfws.dev`
- **Forward Hostname/IP:** `10.9.0.30` (Docker host)
- **Forward Port:** `3100`
- **SSL:** Request new Let's Encrypt certificate

### 6. Configure Authentik

See [docs/authentik-setup.md](docs/authentik-setup.md) for detailed Authentik OIDC provider configuration.

### 7. Initial admin setup

After first start, the database migration and seed data run automatically. Then create the initial admin:

```bash
curl -k -X POST "https://<your-domain>/admin/initial-admin" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "email=admin@example.com&password=changeme"
```

> **Note:** The `/admin/initial-admin` endpoint only works when no admin user exists yet.

Then log in at `https://<your-domain>/sign-in` with your email and password.

### 8. Configure OIDC in leihs (optional)

After deploying with OIDC (`COMPOSE_FILE=docker-compose.yml:docker-compose.oidc.yml`), register the external authentication system in the database:

```bash
docker compose exec leihs-db psql -U leihs -d leihs
```

```sql
-- Insert OIDC external auth system (keys are auto-generated in keys/ directory)
INSERT INTO authentication_systems (
  id, name, description, type, enabled, priority,
  internal_private_key, internal_public_key, external_public_key,
  external_sign_in_url, send_email
) VALUES (
  'oidc', 'Sign in via Authentik', 'OIDC SSO via Authentik', 'external', true, 10,
  '<contents of keys/leihs-private.pem>',
  '<contents of keys/leihs-public.pem>',
  '<contents of keys/oidc-bridge-public.pem>',
  'https://<your-domain>/authenticators/oidc/login',
  true
);

-- Set external base URL (required for JWT claims)
INSERT INTO system_and_security_settings (id, external_base_url)
VALUES (0, 'https://<your-domain>')
ON CONFLICT (id) DO UPDATE SET external_base_url = EXCLUDED.external_base_url;

-- Enable OIDC for all users
INSERT INTO authentication_systems_groups (authentication_system_id, group_id)
VALUES ('oidc', '4dd87663-f731-5766-b97d-9494889ca66c') ON CONFLICT DO NOTHING;
```

Users are matched by email between Authentik and leihs.

## OIDC Authentication Flow

Since leihs uses a custom JWT-based external authentication system (not standard OIDC), a bridge service translates between protocols:

```
1. User clicks "Sign in via Authentik" on leihs login page
2. leihs creates JWT token, redirects to oidc-bridge
3. oidc-bridge verifies leihs JWT, stores state, redirects to Authentik
4. User authenticates at Authentik (SSO)
5. Authentik redirects back to oidc-bridge with authorization code
6. oidc-bridge exchanges code for tokens, extracts user email
7. oidc-bridge creates signed JWT with user identity
8. oidc-bridge redirects back to leihs with signed JWT
9. leihs verifies JWT signature and creates user session
```

## Updating

```bash
cd leihs-docker
git pull
docker compose build --no-cache
docker compose up -d
```

The database migration container runs automatically on startup.

## Troubleshooting

**White screen / blank page:**
The leihs Clojure backends (http-kit) do not set `Content-Type` headers for static JS/CSS files. The nginx config includes a fix that forces correct MIME types via `map` + `proxy_hide_header` + `add_header`. If you see a blank page, check that the nginx config is up to date and the `X-Content-Type-Options: nosniff` header is paired with correct Content-Types.

**Seed data missing after migration:**
If the `password` authentication system or `All Users` group are missing, check the db-migrate logs:
```bash
docker compose logs leihs-db-migrate | grep -i "seed\|password\|error"
```
The seed step requires `PGPASSWORD` to connect — this is set automatically via `DB_PASSWORD`.

Check service logs:
```bash
docker compose logs -f leihs-legacy
docker compose logs -f leihs-admin
docker compose logs -f leihs-oidc-bridge
docker compose logs -f leihs-db-migrate
```

Check database:
```bash
docker compose exec leihs-db psql -U leihs -d leihs
```

## License

This Docker packaging is provided under the same [GPL-3.0 license](https://www.gnu.org/licenses/gpl-3.0.txt) as leihs itself.

leihs is (C) Zürcher Hochschule der Künste (Zurich University of the Arts), Functional LLC, and contributors.
