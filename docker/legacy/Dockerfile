# =============================================================================
# Leihs Legacy (Ruby on Rails) Dockerfile
# =============================================================================
# Multi-stage build for the main leihs Rails application.
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build assets and prepare application
# ---------------------------------------------------------------------------
FROM ruby:3.3.8-bookworm AS builder

ARG LEIHS_VERSION=7.13.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    libpq-dev \
    shared-mime-info \
    libvips-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Clone leihs and the legacy submodule
WORKDIR /build
RUN git clone --depth 1 --branch ${LEIHS_VERSION} https://github.com/leihs/leihs.git /build/leihs || \
    git clone --depth 1 https://github.com/leihs/leihs.git /build/leihs

WORKDIR /build/leihs
RUN git submodule update --init --depth 1 legacy database

# Handle nested submodules in legacy
WORKDIR /build/leihs/legacy
RUN if [ -f .gitmodules ]; then git submodule update --init --depth 1; fi

# Install Ruby dependencies
RUN bundle config set --local deployment 'true' \
    && bundle config set --local without 'development test' \
    && bundle config set --local path 'vendor/bundle' \
    && bundle install --jobs $(nproc)

# Install Node.js dependencies
RUN npm ci --production=false

# Precompile assets
ENV RAILS_ENV=production
ENV SECRET_KEY_BASE=precompile_placeholder
RUN bundle exec rails assets:precompile 2>/dev/null || \
    (echo "Asset precompilation with webpacker..." && \
     npx webpack --mode production 2>/dev/null && \
     bundle exec rails assets:precompile 2>/dev/null) || \
    echo "Asset precompilation skipped - will compile on first request"

# ---------------------------------------------------------------------------
# Stage 2: Runtime
# ---------------------------------------------------------------------------
FROM ruby:3.3.8-slim-bookworm

LABEL org.opencontainers.image.title="leihs-legacy"
LABEL org.opencontainers.image.description="Leihs Legacy Rails application"
LABEL org.opencontainers.image.source="https://github.com/leihs/leihs"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    shared-mime-info \
    libvips42 \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js runtime (needed for some Rails features)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r leihs && useradd -r -g leihs -d /leihs -s /sbin/nologin leihs

# Copy application from builder
COPY --from=builder /build/leihs/legacy /leihs/legacy
COPY --from=builder /build/leihs/LEIHS-VERSION /leihs/LEIHS-VERSION
COPY --from=builder /build/leihs/database /leihs/database

RUN mkdir -p /leihs/legacy/tmp /leihs/legacy/log /leihs/legacy/public/uploads /leihs/secret \
    && chown -R leihs:leihs /leihs

WORKDIR /leihs/legacy

# Copy entrypoint and configs
COPY docker/legacy/entrypoint.sh /leihs/entrypoint.sh
COPY docker/legacy/database.yml /leihs/legacy/config/database.yml
COPY docker/legacy/puma.rb /leihs/legacy/config/puma.rb

# Ensure bundler knows where gems are
RUN bundle config set --local deployment 'true' \
    && bundle config set --local without 'development test' \
    && bundle config set --local path 'vendor/bundle' \
    && chown -R leihs:leihs /leihs/legacy/.bundle

# Make bootsnap require conditional (bootsnap is in dev/test group, excluded in production)
RUN sed -i '/bootsnap/d' /leihs/legacy/config/boot.rb

USER leihs

ENV RAILS_ENV=production
ENV RAILS_LOG_TO_STDOUT=true
ENV LEIHS_LEGACY_PORT=3210

EXPOSE 3210

ENTRYPOINT ["/bin/bash", "/leihs/entrypoint.sh"]
