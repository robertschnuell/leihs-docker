# =============================================================================
# Leihs OIDC Bridge - Authentik ↔ leihs JWT Authentication
# =============================================================================
# Bridges standard OpenID Connect (Authentik) with leihs's custom JWT-based
# external authentication system.
# =============================================================================

FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r leihs && useradd -r -g leihs -d /app -s /sbin/nologin leihs

WORKDIR /app

COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app/

RUN chown -R leihs:leihs /app

USER leihs

ENV FLASK_ENV=production
ENV OIDC_BRIDGE_PORT=3300

EXPOSE 3300

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -f http://localhost:3300/health || exit 1

CMD ["python", "app.py"]
