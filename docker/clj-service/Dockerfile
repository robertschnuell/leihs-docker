# =============================================================================
# Leihs Clojure Service Dockerfile (multi-stage)
# =============================================================================
# Builds a single Clojure service (admin, borrow, my, procure, mail)
# into a lean JVM runtime container.
#
# Build args:
#   LEIHS_VERSION - Git tag to checkout (e.g., 7.13.3)
#   SERVICE_NAME  - Service to build (admin, borrow, my, procure, mail)
#   SERVICE_PORT  - HTTP port for the service
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build the uberjar
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

ARG LEIHS_VERSION=7.13.3
ARG SERVICE_NAME

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    gnupg \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Java (Zulu 17)
RUN curl -fsSL https://repos.azul.com/azul-repo.key | gpg --dearmor -o /usr/share/keyrings/azul.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/azul.gpg] https://repos.azul.com/zulu/deb stable main" > /etc/apt/sources.list.d/zulu.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends zulu17-jdk \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Clojure CLI
RUN curl -fsSL https://download.clojure.org/install/linux-install-1.11.1.1413.sh | bash

# Clone the specific service repository
WORKDIR /build
RUN git clone --depth 1 --branch ${LEIHS_VERSION} https://github.com/leihs/leihs.git /build/leihs || \
    git clone --depth 1 https://github.com/leihs/leihs.git /build/leihs

# Clone service submodule
WORKDIR /build/leihs
RUN git submodule update --init --depth 1 ${SERVICE_NAME} database

# Clone shared-clj if it exists as a submodule of the service
WORKDIR /build/leihs/${SERVICE_NAME}
RUN if [ -f .gitmodules ]; then \
      # Initialize all submodules listed in .gitmodules
      git submodule update --init --depth 1 --recursive; \
    fi

# Bypass asdf/mise setup scripts — tools are already installed in this image
RUN for setup_script in bin/env/java-setup bin/env/clojure-setup bin/env/nodejs-setup; do \
      if [ -f "$setup_script" ]; then \
        echo '#!/bin/bash' > "$setup_script" && echo 'echo "Skipping tool setup (Docker)"' >> "$setup_script"; \
      fi; \
    done \
    && if [ -f "bin/env/asdf-helper.bash" ]; then \
      printf '#!/bin/bash\nfunction asdf-load() { true; }\nfunction asdf-update-plugin() { true; }\nfunction asdf-update-plugin-base() { true; }\n' > bin/env/asdf-helper.bash; \
    fi \
    && if [ -f "bin/env/select-tool-versions-manager" ]; then \
      printf '#!/bin/bash\nexport TOOL_VERSIONS_MANAGER=asdf\n' > bin/env/select-tool-versions-manager; \
    fi

# Also patch the UI subproject's setup scripts if present
RUN if [ -d "ui/bin/env" ]; then \
      for setup_script in ui/bin/env/java-setup ui/bin/env/clojure-setup ui/bin/env/nodejs-setup; do \
        if [ -f "$setup_script" ]; then \
          echo '#!/bin/bash' > "$setup_script" && echo 'echo "Skipping tool setup (Docker)"' >> "$setup_script"; \
        fi; \
      done; \
    fi \
    && if [ -f "ui/bin/env/asdf-helper.bash" ]; then \
      printf '#!/bin/bash\nfunction asdf-load() { true; }\nfunction asdf-update-plugin() { true; }\nfunction asdf-update-plugin-base() { true; }\n' > ui/bin/env/asdf-helper.bash; \
    fi

# Install npm dependencies if package.json exists
RUN if [ -f package.json ]; then npm ci --production=false; fi
# For procure: client is a separate directory
RUN if [ -d client ] && [ -f client/package.json ]; then cd client && npm ci --ignore-scripts --no-audit && cd ..; fi

# Build ClojureScript/JS frontend
RUN if [ -f bin/cljs-release ]; then \
      chmod +x bin/cljs-release && ./bin/cljs-release; \
    elif [ -d client ] && [ -f client/bin/build ]; then \
      chmod +x client/bin/build && client/bin/build; \
    fi

# Build the uberjar
RUN if [ -f bin/clj-uberjar ]; then \
      chmod +x bin/clj-uberjar && ./bin/clj-uberjar; \
    elif [ -f server/bin/clj-uberjar ]; then \
      chmod +x server/bin/clj-uberjar && server/bin/clj-uberjar; \
    elif [ -f deps.edn ]; then \
      clojure -T:build uber; \
    elif [ -f server/deps.edn ]; then \
      cd server && clojure -T:build uber && cd ..; \
    fi

# Find the built jar (search in target/ and server/target/ for procure)
RUN find /build/leihs/${SERVICE_NAME} -name "leihs-*.jar" -o -name "*.standalone.jar" 2>/dev/null | head -1 > /tmp/jar-path \
    && if [ -s /tmp/jar-path ]; then \
         cp "$(cat /tmp/jar-path)" /build/service.jar; \
       else \
         find /build/leihs/${SERVICE_NAME} -path "*/target/*.jar" -type f 2>/dev/null | head -1 > /tmp/jar-path && \
         cp "$(cat /tmp/jar-path)" /build/service.jar; \
       fi

# ---------------------------------------------------------------------------
# Stage 2: Lean runtime
# ---------------------------------------------------------------------------
FROM eclipse-temurin:17-jdk-jammy

ARG SERVICE_NAME
ARG SERVICE_PORT=3200

LABEL org.opencontainers.image.title="leihs-${SERVICE_NAME}"
LABEL org.opencontainers.image.description="Leihs ${SERVICE_NAME} service"
LABEL org.opencontainers.image.source="https://github.com/leihs/leihs"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -r leihs && useradd -r -g leihs -d /leihs -s /sbin/nologin leihs
RUN mkdir -p /leihs/secret /leihs/tmp /leihs/log \
    && chown -R leihs:leihs /leihs

COPY --from=builder /build/service.jar /leihs/service.jar

USER leihs
WORKDIR /leihs

ENV SERVICE_NAME=${SERVICE_NAME}
ENV HTTP_PORT=${SERVICE_PORT}
ENV JAVA_OPTS="-Xmx512m"

EXPOSE ${SERVICE_PORT}

# The entrypoint reads the master secret and starts the JVM
COPY docker/clj-service/entrypoint.sh /leihs/entrypoint.sh

ENTRYPOINT ["/bin/bash", "/leihs/entrypoint.sh"]
