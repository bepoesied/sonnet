# https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian&sort=elixir_version,erlang_version,os_version
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.0.6
ARG DEBIAN_VERSION=trixie-20260824-slim
ARG NODE_VERSION=24
ARG PNPM_VERSION=12

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG NODE_BUILDER_IMAGE="ghcr.io/pnpm/pnpm:${PNPM_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${NODE_BUILDER_IMAGE} as node-builder
RUN pnpm runtime set node ${NODE_VERSION} -g

# prepare build dir
RUN mkdir -p /app/assets
WORKDIR /app

# set build ENV
ENV NODE_ENV=prod

# install npm dependencies
COPY assets/package.json assets/pnpm-lock.yaml ./assets/
RUN pnpm --prefix assets ci

# build assets
COPY assets assets

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

COPY --from=node-builder /app/assets assets

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
        libstdc++6 openssl libncurses6 \
        locales ca-certificates tini ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/sonnet ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]
ENTRYPOINT [ "/usr/bin/tini", "--" ]
CMD ["/app/bin/server"]
