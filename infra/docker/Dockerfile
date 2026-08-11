# syntax=docker/dockerfile:1.7
#
# One image, many roles (ADR-001). The role is chosen at runtime with NEXUS_ROLE;
# there is deliberately no per-role image, because divergent images are how
# "the worker is running a different build" incidents happen.
#
# Build:  docker build -f infra/docker/Dockerfile -t aegis-nexus/control-plane .
# Run:    docker run -e NEXUS_ROLE=api -p 3000:3000 aegis-nexus/control-plane

ARG RUBY_VERSION=3.2.2

# ---- Build stage -----------------------------------------------------------
FROM ruby:${RUBY_VERSION}-slim AS build

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Gems first: this layer changes far less often than application code.
COPY apps/control-plane/Gemfile apps/control-plane/Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY apps/control-plane/ ./

# Precompile bootsnap so every role boots fast rather than paying it per pod.
RUN bundle exec bootsnap precompile app/ domains/ infrastructure/ lib/ config/

# ---- Runtime stage ---------------------------------------------------------
FROM ruby:${RUBY_VERSION}-slim AS runtime

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development \
    RAILS_LOG_TO_STDOUT=1

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libpq5 tini && \
    rm -rf /var/lib/apt/lists/*

# Non-root. The document-parsing role handles hostile input; running any role as
# root would make a parser bug a container escape rather than a crash.
RUN groupadd --system --gid 1000 nexus && \
    useradd --system --uid 1000 --gid 1000 --create-home nexus

WORKDIR /app
COPY --from=build --chown=nexus:nexus /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=nexus:nexus /app /app

USER nexus:nexus

EXPOSE 3000

# Every role must answer a liveness probe, including the ones with no HTTP
# server — the entrypoint starts a minimal probe listener for those.
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -fsS http://localhost:3000/healthz || exit 1

# tini reaps zombies and forwards SIGTERM, which is what makes graceful drain
# work: workers must finish or release their leases rather than being killed
# mid-step (ADR-006 constraint 2).
ENTRYPOINT ["/usr/bin/tini", "--", "./bin/role-entrypoint"]
CMD []
