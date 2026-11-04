# The control plane's image: its release (Phoenix, the domain and the
# protocol, never the runner) on the same Elixir/OTP image it was built with,
# so the release's runtime matches the system's libraries.
#
#   make image   (docker build --build-arg CP_VERSION=<versão> -t pipemaestro .)
#   docker run -p 4000:4000 -e DATABASE_URL=... -e SECRET_KEY_BASE=... \
#     -e SECRETS_KEY=... -e PHX_HOST=plataforma.exemplo.com pipemaestro
#
# See docs/guias/instalacao.md.
ARG ELIXIR_IMAGE=elixir:1.20.4-otp-28-slim

FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update -y && apt-get install -y build-essential git curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so they stay cached while the code changes.
COPY mix.exs mix.lock ./
COPY apps/pipe_maestro/mix.exs apps/pipe_maestro/
COPY apps/pipe_maestro_web/mix.exs apps/pipe_maestro_web/
COPY apps/pipe_maestro_protocol/mix.exs apps/pipe_maestro_protocol/
COPY apps/pipe_maestro_runner/mix.exs apps/pipe_maestro_runner/
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY apps apps
COPY config/runtime.exs config/
COPY rel rel

# The image has no .git to read its version from: `make image` passes it
# (PipeMaestroProtocol.Version.Git); without it, dev+unknown.
ARG CP_VERSION=""
ENV CP_VERSION=${CP_VERSION}

RUN mix compile \
    && cd apps/pipe_maestro_web && mix assets.deploy && cd ../.. \
    && mix release pipe_maestro

FROM ${ELIXIR_IMAGE}

RUN apt-get update -y && apt-get install -y openssl ca-certificates locales \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod
WORKDIR /app
RUN useradd --create-home app
COPY --from=build --chown=app:app /app/_build/prod/rel/pipe_maestro ./
USER app

EXPOSE 4000
CMD ["/app/bin/server"]
