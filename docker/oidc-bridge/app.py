"""
Leihs OIDC Bridge - Authentik ↔ leihs JWT Authentication

Bridges standard OpenID Connect (Authentik) with leihs's custom JWT-based
external authentication system using ES256 key pairs.

Flow:
  1. leihs redirects user to this bridge with a signed JWT token (ES256)
     URL: {external_sign_in_url}?token=<JWT>
     JWT signed with authentication_system.internal_private_key
     JWT claims: {email, login, org_id, server_base_url, return_to, path}

  2. Bridge verifies the JWT, stores context in session
  3. Bridge redirects user to Authentik OIDC authorize endpoint
  4. User authenticates at Authentik
  5. Authentik redirects back with authorization code
  6. Bridge exchanges code for tokens, extracts user email
  7. Bridge creates response JWT signed with bridge's private key (ES256)
     JWT claims: {email, success, sign_in_request_token, exp, iat}
  8. Bridge redirects to {server_base_url}{path}?token=<response_JWT>
     where path = /sign-in/external-authentication/{auth-system-id}

  leihs verifies the response JWT using authentication_system.external_public_key
  (which must be set to the bridge's public key in the leihs admin panel).
"""

import os
import sys
import time
import secrets
import logging

import jwt
import requests
from flask import Flask, request, redirect, session, jsonify
from cryptography.hazmat.primitives import serialization
from authlib.integrations.requests_client import OAuth2Session

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", secrets.token_hex(32))

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AUTHENTIK_ISSUER_URL = os.environ["AUTHENTIK_ISSUER_URL"].rstrip("/")
AUTHENTIK_CLIENT_ID = os.environ["AUTHENTIK_CLIENT_ID"]
AUTHENTIK_CLIENT_SECRET = os.environ["AUTHENTIK_CLIENT_SECRET"]
OIDC_REDIRECT_URI = os.environ["OIDC_REDIRECT_URI"]
LEIHS_EXTERNAL_BASE_URL = os.environ.get("LEIHS_EXTERNAL_BASE_URL", "https://localhost")
BRIDGE_PORT = int(os.environ.get("OIDC_BRIDGE_PORT", "3300"))

BRIDGE_PRIVATE_KEY_PATH = os.environ.get("BRIDGE_PRIVATE_KEY_PATH", "/keys/oidc-bridge-private.pem")
# The "leihs internal public key" is the public half of the key stored as
# internal_private_key in the authentication_systems table. leihs uses it to
# sign the outgoing JWT tokens that this bridge must verify.
LEIHS_INTERNAL_PUBLIC_KEY_PATH = os.environ.get("LEIHS_PUBLIC_KEY_PATH", "/keys/leihs-public.pem")


def load_key(path):
    """Load a PEM key file."""
    with open(path, "rb") as f:
        return f.read()


# Lazy-loaded keys (loaded on first use so container can start even if keys missing)
_bridge_private_key = None
_leihs_internal_public_key = None


def get_bridge_private_key():
    """The bridge's own private key. Used to sign response JWTs back to leihs.
    The corresponding public key must be registered as `external_public_key`
    in the authentication_systems table in leihs."""
    global _bridge_private_key
    if _bridge_private_key is None:
        _bridge_private_key = serialization.load_pem_private_key(
            load_key(BRIDGE_PRIVATE_KEY_PATH), password=None
        )
    return _bridge_private_key


def get_leihs_internal_public_key():
    """The public key matching leihs's `internal_private_key`.
    Used to verify incoming JWT tokens from leihs."""
    global _leihs_internal_public_key
    if _leihs_internal_public_key is None:
        _leihs_internal_public_key = serialization.load_pem_public_key(
            load_key(LEIHS_INTERNAL_PUBLIC_KEY_PATH)
        )
    return _leihs_internal_public_key


# ---------------------------------------------------------------------------
# OIDC Discovery
# ---------------------------------------------------------------------------
_oidc_config = None


def get_oidc_config():
    """Fetch and cache the OIDC provider configuration."""
    global _oidc_config
    if _oidc_config is None:
        discovery_url = f"{AUTHENTIK_ISSUER_URL}/.well-known/openid-configuration"
        logger.info(f"Fetching OIDC discovery from {discovery_url}")
        resp = requests.get(discovery_url, timeout=10)
        resp.raise_for_status()
        _oidc_config = resp.json()
        logger.info(f"OIDC config loaded: authorization_endpoint={_oidc_config.get('authorization_endpoint')}")
    return _oidc_config


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/health")
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok", "service": "leihs-oidc-bridge"})


@app.route("/authenticators/oidc/login")
def oidc_login():
    """
    Entry point from leihs. leihs sends the user here with a JWT token
    containing the user's identity claims.

    Query params:
      - token: JWT signed by leihs internal_private_key (ES256)
        Claims: {email, login, org_id, server_base_url, return_to, path}
    """
    leihs_token = request.args.get("token")

    if not leihs_token:
        logger.warning("No token provided by leihs")
        return "Missing authentication token", 400

    try:
        # Verify the JWT from leihs using the internal public key
        payload = jwt.decode(
            leihs_token,
            get_leihs_internal_public_key(),
            algorithms=["ES256"],
            options={"verify_exp": True}
        )
        logger.info(f"Verified leihs token, claims: server_base_url={payload.get('server_base_url')}, path={payload.get('path')}")
    except jwt.ExpiredSignatureError:
        logger.warning("leihs token expired")
        return "Authentication token expired", 401
    except jwt.InvalidTokenError as e:
        logger.warning(f"Invalid leihs token: {e}")
        return "Invalid authentication token", 401

    # Store leihs context in session for the callback
    session["leihs_token_payload"] = payload
    session["leihs_original_token"] = leihs_token
    # The path where we must redirect back (e.g., /sign-in/external-authentication/<auth-system-id>)
    session["leihs_callback_path"] = payload.get("path", "")
    # The server base URL to redirect back to
    session["leihs_server_base_url"] = payload.get("server_base_url", LEIHS_EXTERNAL_BASE_URL)

    # Generate OIDC state for CSRF protection
    state = secrets.token_urlsafe(32)
    session["oidc_state"] = state

    # Redirect to Authentik OIDC authorization
    oidc_config = get_oidc_config()
    auth_url = oidc_config["authorization_endpoint"]

    oauth = OAuth2Session(
        client_id=AUTHENTIK_CLIENT_ID,
        client_secret=AUTHENTIK_CLIENT_SECRET,
        redirect_uri=OIDC_REDIRECT_URI,
        scope="openid email profile"
    )

    authorization_url, _ = oauth.create_authorization_url(
        auth_url,
        state=state
    )

    logger.info(f"Redirecting to Authentik: {authorization_url}")
    return redirect(authorization_url)


@app.route("/authenticators/oidc/callback")
def oidc_callback():
    """
    Callback from Authentik after user authenticates.
    Exchanges authorization code for tokens, extracts user email,
    creates leihs-compatible JWT, and redirects back to leihs.
    """
    # Verify state
    state = request.args.get("state")
    stored_state = session.get("oidc_state")

    if not state or state != stored_state:
        logger.warning("OIDC state mismatch")
        return "Invalid state parameter", 400

    error = request.args.get("error")
    if error:
        error_desc = request.args.get("error_description", "Unknown error")
        logger.warning(f"OIDC error: {error} - {error_desc}")
        return f"Authentication failed: {error_desc}", 401

    code = request.args.get("code")
    if not code:
        logger.warning("No authorization code received")
        return "Missing authorization code", 400

    # Exchange code for tokens
    oidc_config = get_oidc_config()
    token_url = oidc_config["token_endpoint"]

    oauth = OAuth2Session(
        client_id=AUTHENTIK_CLIENT_ID,
        client_secret=AUTHENTIK_CLIENT_SECRET,
        redirect_uri=OIDC_REDIRECT_URI
    )

    try:
        token_response = oauth.fetch_token(
            token_url,
            code=code,
            grant_type="authorization_code"
        )
    except Exception as e:
        logger.error(f"Token exchange failed: {e}")
        return "Failed to exchange authorization code", 500

    # Extract user info from ID token or userinfo endpoint
    user_email = None

    # Try to get email from ID token
    id_token = token_response.get("id_token")
    if id_token:
        try:
            # Verify ID token signature using Authentik's JWKS
            jwks_uri = oidc_config.get("jwks_uri")
            if jwks_uri:
                jwks_resp = requests.get(jwks_uri, timeout=10)
                jwks_resp.raise_for_status()
                from jwt import PyJWKClient
                jwk_client = PyJWKClient(jwks_uri)
                signing_key = jwk_client.get_signing_key_from_jwt(id_token)
                id_claims = jwt.decode(
                    id_token,
                    signing_key.key,
                    algorithms=["RS256", "ES256"],
                    audience=AUTHENTIK_CLIENT_ID,
                    options={"verify_exp": True}
                )
            else:
                # Fallback: decode without verification if no JWKS URI
                id_claims = jwt.decode(id_token, options={"verify_signature": False})
            user_email = id_claims.get("email")
            logger.info(f"Got email from ID token: {user_email}")
        except Exception as e:
            logger.warning(f"Could not verify/decode ID token: {e}")

    # Fallback: fetch from userinfo endpoint
    if not user_email:
        userinfo_url = oidc_config.get("userinfo_endpoint")
        if userinfo_url:
            try:
                userinfo_resp = oauth.get(userinfo_url)
                userinfo_resp.raise_for_status()
                userinfo = userinfo_resp.json()
                user_email = userinfo.get("email")
                logger.info(f"Got email from userinfo: {user_email}")
            except Exception as e:
                logger.error(f"Userinfo request failed: {e}")

    if not user_email:
        logger.error("Could not determine user email from OIDC tokens")
        return "Could not determine user identity", 500

    # Retrieve the original leihs context
    leihs_payload = session.get("leihs_token_payload", {})
    leihs_callback_path = session.get("leihs_callback_path", "")
    leihs_server_base_url = session.get("leihs_server_base_url", LEIHS_EXTERNAL_BASE_URL)

    # Create the JWT response token for leihs
    # leihs expects these claims (see leihs.core.sign-in.external-authentication.back):
    #   - email: user's email to match against users table
    #   - success: true (required, checked via :success key)
    #   - sign_in_request_token: the original JWT token from step 1 (verified by leihs)
    now = int(time.time())
    leihs_response_payload = {
        "email": user_email,
        "success": True,
        "sign_in_request_token": session.get("leihs_original_token", ""),
        "iat": now,
        "exp": now + 120,  # 2-minute validity
    }

    response_token = jwt.encode(
        leihs_response_payload,
        get_bridge_private_key(),
        algorithm="ES256"
    )

    # Clear session data
    session.pop("leihs_token_payload", None)
    session.pop("leihs_original_token", None)
    session.pop("leihs_callback_path", None)
    session.pop("leihs_server_base_url", None)
    session.pop("oidc_state", None)

    # Redirect back to leihs at the path specified in the original token
    # URL: {server_base_url}{path}?token={response_JWT}
    callback_url = f"{leihs_server_base_url}{leihs_callback_path}?token={response_token}"

    logger.info(f"Authentication successful for {user_email}, redirecting to leihs")
    return redirect(callback_url)


@app.route("/authenticators/oidc/info")
def oidc_info():
    """Info endpoint (does not expose sensitive configuration)."""
    return jsonify({
        "service": "leihs-oidc-bridge",
        "status": "ok"
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logger.info(f"Starting leihs OIDC bridge on port {BRIDGE_PORT}")
    logger.info(f"Authentik issuer: {AUTHENTIK_ISSUER_URL}")
    logger.info(f"leihs base URL: {LEIHS_EXTERNAL_BASE_URL}")

    from gunicorn.app.base import BaseApplication

    class StandaloneApplication(BaseApplication):
        def __init__(self, app, options=None):
            self.options = options or {}
            self.application = app
            super().__init__()

        def load_config(self):
            for key, value in self.options.items():
                if key in self.cfg.settings and value is not None:
                    self.cfg.set(key.lower(), value)

        def load(self):
            return self.application

    options = {
        "bind": f"0.0.0.0:{BRIDGE_PORT}",
        "workers": 2,
        "accesslog": "-",
        "errorlog": "-",
        "loglevel": "info",
    }

    StandaloneApplication(app, options).run()
