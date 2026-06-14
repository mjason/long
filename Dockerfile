# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
# https://hub.docker.com/_/ubuntu/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260518-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: docker.io/hexpm/elixir:1.19.5-erlang-28.2-debian-trixie-20260518-slim
#
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.2
ARG DEBIAN_VERSION=trixie-20260518-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates curl unzip inotify-tools procps \
       libnss3 libnspr4 libgbm1 libdrm2 libxkbcommon0 libexpat1 \
       libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxext6 libx11-6 \
       libpango-1.0-0 libcairo2 libasound2t64 libatk1.0-0t64 \
       libatk-bridge2.0-0t64 libcups2t64 fonts-liberation fonts-noto-cjk \
  && rm -rf /var/lib/apt/lists/*

# Pre-install Deno (the code_run sandbox) and Obscura (the web_scan browser)
# onto PATH so the running app never downloads them at runtime
# (LONG_AUTO_INSTALL_BINARIES=false below). Their Engines call
# Installer.locate/2 first and find these. TARGETARCH is injected by
# buildx (amd64 / arm64), so one Dockerfile builds both architectures.
ARG TARGETARCH
RUN set -eux; \
  case "$TARGETARCH" in \
    amd64) DENO_ARCH=x86_64-unknown-linux-gnu; OBS_ARCH=x86_64-linux ;; \
    arm64) DENO_ARCH=aarch64-unknown-linux-gnu; OBS_ARCH=aarch64-linux ;; \
    *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/deno.zip "https://github.com/denoland/deno/releases/latest/download/deno-${DENO_ARCH}.zip"; \
  unzip -o /tmp/deno.zip -d /usr/local/bin && chmod +x /usr/local/bin/deno; \
  curl -fsSL -o /tmp/obscura.tgz "https://github.com/h4ckf0r0day/obscura/releases/latest/download/obscura-${OBS_ARCH}.tar.gz"; \
  tar -xzf /tmp/obscura.tgz -C /tmp; \
  find /tmp -type f -name obscura -exec install -m0755 {} /usr/local/bin/obscura \; ; \
  rm -rf /tmp/deno.zip /tmp/obscura*; \
  test -x /usr/local/bin/deno && test -x /usr/local/bin/obscura

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app && mkdir -p /data && chown nobody /data

# set runner ENV. Data (SQLite DB + agent workspace/skills/memory) lives on the
# /data volume; binaries are baked in, so skip the runtime auto-download.
ENV MIX_ENV="prod" \
    DATABASE_PATH="/data/long.db" \
    LONG_WORKSPACE_ROOT="/data/agent" \
    LONG_AUTO_INSTALL_BINARIES="false"

VOLUME ["/data"]
EXPOSE 4000

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/long ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
