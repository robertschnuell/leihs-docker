# =============================================================================
# Leihs Database Migration Dockerfile
# =============================================================================
# Runs database migrations on startup. Uses the leihs database submodule
# which is a Rails app containing all migration files.
# =============================================================================

FROM ruby:3.3.8-bookworm

ARG LEIHS_VERSION=7.13.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    libpq-dev \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Clone leihs and the database submodule (contains migrations)
WORKDIR /build
RUN git clone --depth 1 --branch ${LEIHS_VERSION} https://github.com/leihs/leihs.git /build/leihs || \
    git clone --depth 1 https://github.com/leihs/leihs.git /build/leihs

WORKDIR /build/leihs
RUN git submodule update --init --depth 1 database

# Install Ruby dependencies for the database app
WORKDIR /build/leihs/database
RUN bundle config set --local deployment 'true' \
    && bundle config set --local without 'test' \
    && bundle config set --local path 'vendor/bundle' \
    && bundle install --jobs $(nproc)

COPY docker/db-migrate/migrate.sh /migrate.sh
COPY docker/legacy/database.yml /build/leihs/database/config/database.yml
RUN chmod +x /migrate.sh

# Run as non-root user
RUN groupadd -r leihs && useradd -r -g leihs -d /build -s /sbin/nologin leihs \
    && chown -R leihs:leihs /build
USER leihs

ENV RAILS_ENV=production

ENTRYPOINT ["/migrate.sh"]
