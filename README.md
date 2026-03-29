# Leihs Docker Compose Deployment

A Docker Compose setup for [leihs](https://github.com/leihs/leihs) — the equipment booking and inventory management system developed by Zurich University of the Arts.

> **Note:** This is an unofficial, community-maintained Docker deployment. Leihs is officially deployed via Ansible to bare-metal Debian/Ubuntu servers. This project packages all services into Docker containers for easier infrastructure integration.

## Architecture

```
Reverse Proxy (SSL termination)
    │
    ▼
leihs-reverse-proxy (nginx, port 3100)
    │
    ├── /admin/*          → leihs-admin       (Clojure JVM, port 3200)
    ├── /borrow/*         → leihs-borrow      (Clojure JVM, port 3250)
    ├── /my/*             → leihs-my           (Clojure JVM, port 3240)
    ├── /procure/*        → leihs-procure      (Clojure JVM, port 3230)
    ├── /mail/*           → leihs-mail         (Clojure JVM, port 3220)
    ├── /authenticators/* → leihs-oidc-bridge  (Python, port 3300) [optional]
    └── /*                → leihs-legacy       (Ruby/Rails, port 3210)
    │
    └── PostgreSQL 16 (port 5415)
```

## Services

| Service | Technology | Description |
|---------|-----------|-------------|
| `leihs-legacy` | Ruby on Rails 8.x | Main application (lending, inventory management) |
| `leihs-admin` | Clojure (JVM) | Administration interface |
| `leihs-borrow` | Clojure (JVM) | Borrowing and reservation interface |
| `leihs-my` | Clojure (JVM) | User profile, sign-in, and settings |
| `leihs-procure` | Clojure (JVM) | Procurement module |
| `leihs-mail` | Clojure (JVM) | Email processing service |
| `leihs-oidc-bridge` | Python (Flask) | Bridges OIDC providers with leihs JWT auth (optional) |
| `leihs-reverse-proxy` | Nginx | Internal path-based routing with security headers |
| `leihs-db` | PostgreSQL 16 | Shared database |
| `leihs-db-migrate` | Ruby + Clojure | Database migration runner (init container) |

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- At least 8 GB RAM available for containers
- A reverse proxy with SSL termination (Nginx Proxy Manager, Traefik, Caddy, etc.)
- OpenSSL (for secret generation)

## Quick Start

### 1. Clone and prepare

```bash
git clone https://github.com/robertschnuell/leihs-docker.git
cd leihs-docker
```

### 2. Generate secrets

```bash
./scripts/generate-secrets.sh
```

This generates:
- `.env` file with random database password and master secret
- ES256 key pairs in `keys/` for external authentication
- Master secret file in `data/secret/`

### 3. Configure

Edit `.env` with your deployment values:

```env
LEIHS_EXTERNAL_HOSTNAME=leihs.example.com
LEIHS_EXTERNAL_BASE_URL=https://leihs.example.com
```

### 4. Build and start

```bash
docker compose up -d --build
```

The first build takes 15-30 minutes (compiling Clojure uberjars and Rails assets).

### 5. Configure your reverse proxy

Point your reverse proxy to the Docker host on port `3100` (HTTP). The internal nginx handles path routing — your external proxy only needs to terminate SSL and forward traffic.

### 6. Create initial admin user

After all services are running:

```bash
docker compose exec leihs-legacy bin/rails runner "
  user = User.find_or_create_by!(login: 'admin') do |u|
    u.firstname = 'System'
    u.lastname = 'Admin'
    u.email = 'admin@example.com'
    u.is_admin = true
  end
  AuthenticationSystemUser.find_or_create_by!(
    user: user,
    authentication_system: AuthenticationSystem.find_by(id: 'password')
  )
  user.update!(password: 'changeme')
"
```

Log in at `https://leihs.example.com/sign-in` with `admin` / `changeme` and change the password immediately.

## OIDC Authentication (Optional)

Leihs uses a custom JWT-based external authentication system, not standard OIDC. The included OIDC bridge translates between the two protocols, allowing integration with providers like Authentik, Keycloak, or any OpenID Connect provider.

To enable the OIDC bridge, use the compose overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.oidc.yml up -d --build
```

Or set `COMPOSE_FILE` in `.env`:

```env
COMPOSE_FILE=docker-compose.yml:docker-compose.oidc.yml
```

You also need to configure the OIDC-specific variables in `.env`:

```env
AUTHENTIK_ISSUER_URL=https://auth.example.com/application/o/leihs/
AUTHENTIK_CLIENT_ID=<your-client-id>
AUTHENTIK_CLIENT_SECRET=<your-client-secret>
OIDC_REDIRECT_URI=https://leihs.example.com/authenticators/oidc/callback
```

For a step-by-step Authentik setup guide, see [docs/authentik-setup.md](docs/authentik-setup.md).

### Authentication Flow

```
1. User clicks external sign-in button on leihs login page
2. leihs creates a signed JWT token, redirects to the OIDC bridge
3. Bridge verifies the leihs JWT, redirects to the OIDC provider
4. User authenticates at the OIDC provider
5. Provider redirects back to the bridge with an authorization code
6. Bridge exchanges the code for tokens, extracts the user email
7. Bridge creates a signed JWT with the user identity
8. Bridge redirects back to leihs with the signed JWT
9. leihs verifies the JWT signature and creates a user session
```

## Testing

Run the functional test suite against a running deployment:

```bash
export LEIHS_TEST_USER=admin@example.com
export LEIHS_TEST_PASS=yourpassword
./test_all.sh
```

## Updating

```bash
# Pull latest changes
git pull

# Rebuild containers
docker compose build --no-cache

# Restart with new images
docker compose up -d
```

The database migration container runs automatically on startup and applies any pending schema changes.

## Maintenance

### View logs

```bash
docker compose logs -f leihs-legacy
docker compose logs -f leihs-admin
```

### Database backup

```bash
docker compose exec leihs-db pg_dump -U leihs -d leihs > backup_$(date +%Y%m%d).sql
```

### Database shell

```bash
docker compose exec leihs-db psql -U leihs -d leihs
```

## Known Limitations

- The `leihs-inventory` service is not included (requires additional frontend build steps not yet implemented)
- Build times are long due to Clojure uberjar compilation (~15-30 min on first build)
- Requires at least 8 GB RAM — each JVM service needs ~512 MB

## License

This Docker packaging is provided under the [GPL-3.0 license](https://www.gnu.org/licenses/gpl-3.0.txt), the same license as leihs itself.

leihs is developed and maintained by Zürcher Hochschule der Künste (Zurich University of the Arts).
