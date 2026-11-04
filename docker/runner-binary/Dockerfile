# The toolchain that builds the runner's single binaries (Burrito), the same
# on a developer's machine and on the server a deploy builds them on.
#
#   scripts/build_runner_binaries.sh <output dir>   (make runner.binary)
#
# Burrito packs, for each target, the precompiled ERTS of the exact OTP that
# builds it (Burrito.Util.get_otp_version/0, fetched from its CDN). The CDN
# does not publish every patch, so this image pins one it does, apart from
# the hosts' own Erlang (.tool-versions). The binary talks to the control
# plane over a WebSocket, never Erlang distribution, so the two need not
# match. See docs/adr/0020-binarios-do-runner-no-deploy.md.
ARG OTP_IMAGE=erlang:28.5.0.6
FROM ${OTP_IMAGE}

ARG ELIXIR_VERSION=1.20.4
ARG ZIG_VERSION=0.16.0

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends xz-utils unzip ca-certificates curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Zig for the image's own architecture: arm64 on an Apple Silicon Mac,
# x86_64 on the server. Either builds every target.
RUN arch="$(uname -m)" \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && mv "/opt/zig-${arch}-linux-${ZIG_VERSION}" /opt/zig

RUN curl -fsSL -o /tmp/elixir.zip \
       "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-28.zip" \
    && unzip -q /tmp/elixir.zip -d /opt/elixir && rm /tmp/elixir.zip

ENV PATH=/opt/zig:/opt/elixir/bin:$PATH \
    MIX_HOME=/opt/mix \
    LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /work
