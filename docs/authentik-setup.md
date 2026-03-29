# Authentik OIDC Configuration for Leihs

This guide configures [Authentik](https://goauthentik.io/) as an OIDC provider for leihs external authentication.

## Prerequisites

- Authentik instance running and accessible
- Leihs stack running via Docker Compose (with OIDC overlay)
- ES256 keys generated (`./scripts/generate-secrets.sh`)

## 1. Create OAuth2/OIDC Provider in Authentik

1. Open the Authentik admin interface
2. Navigate to **Applications → Providers → Create**
3. Select **OAuth2/OpenID Provider**

| Field | Value |
|---|---|
| Name | `leihs-oidc` |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | `Confidential` |
| Client ID | (auto-generated — copy this for `.env`) |
| Client Secret | (auto-generated — copy this for `.env`) |
| Redirect URIs | `https://leihs.example.com/authenticators/oidc/callback` |
| Signing Key | Select your Authentik signing key |

### Token Settings

| Field | Value |
|---|---|
| Access token validity | `minutes=5` |
| Scopes | `openid`, `email`, `profile` |

4. Click **Finish**

## 2. Create Application in Authentik

1. Navigate to **Applications → Applications → Create**

| Field | Value |
|---|---|
| Name | `Leihs` |
| Slug | `leihs` |
| Provider | `leihs-oidc` (from step 1) |
| Launch URL | `https://leihs.example.com/` |

2. Click **Create**

## 3. Update `.env` Configuration

Set the OIDC variables in your `.env` file:

```bash
AUTHENTIK_ISSUER_URL=https://auth.example.com/application/o/leihs/
AUTHENTIK_CLIENT_ID=<paste Client ID from step 1>
AUTHENTIK_CLIENT_SECRET=<paste Client Secret from step 1>
OIDC_REDIRECT_URI=https://leihs.example.com/authenticators/oidc/callback
```

## 4. Start with OIDC Overlay

```bash
docker compose -f docker-compose.yml -f docker-compose.oidc.yml up -d --build
```

## 5. Configure leihs Authentication System

After leihs is running and you have admin access:

1. Log in as admin at `https://leihs.example.com/admin/`
2. Go to **System → Authentication Systems → Add Authentication System**
3. Configure:

| Field | Value |
|---|---|
| ID | `oidc` |
| Name | `Sign in via Authentik` |
| Type | `external` |
| External Sign-in URL | `https://leihs.example.com/authenticators/oidc/login` |
| External public key | Contents of `keys/oidc-bridge-public.pem` |
| Internal private key | Contents of `keys/leihs-private.pem` |
| Internal public key | Contents of `keys/leihs-public.pem` |
| Enabled | Yes |

4. Save the authentication system.

## 6. Assign Users

For each user that should use Authentik login:

1. Go to **Users → Edit User**
2. Under **Authentication Systems**, add the `oidc` system
3. The user's email in leihs must match their email in Authentik

To enable for all users at once, add the `oidc` authentication system to a group (e.g., the default "All Users" group).

## 7. Test

1. Open the leihs sign-in page in a private browser window
2. Enter a user email that exists in both leihs and Authentik
3. Click **Sign in via Authentik**
4. Authenticate at Authentik
5. You should be redirected back to leihs, signed in

## Troubleshooting

### "Invalid authentication token" error
- Verify ES256 keys in leihs admin match the files in `keys/`
- Check time synchronization between containers

### "Could not determine user identity" error
- Ensure the Authentik application has `email` scope enabled
- Verify the user has a confirmed email in Authentik

### User not found after OIDC login
- The email from Authentik must exactly match a user's email in leihs
- Create the user in leihs first, or use bulk import

### View OIDC bridge logs
```bash
docker compose logs -f leihs-oidc-bridge
```

### Verify OIDC discovery endpoint
```bash
curl https://auth.example.com/application/o/leihs/.well-known/openid-configuration
```
