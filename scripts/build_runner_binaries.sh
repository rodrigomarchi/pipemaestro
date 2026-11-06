#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Builds the runner's single binaries (Burrito) in the toolchain image
# (docker/runner-binary), the same here and on the server.
#
# Usage:  scripts/build_runner_binaries.sh <output dir>
#         BURRITO_TARGET=macos_arm64 scripts/build_runner_binaries.sh burrito_out
#
# Writes pipemaestro_<target> for each target (all four unless
# BURRITO_TARGET names one) and a SHA256SUMS into <output dir>.
#
# The checkout's sources (uncommitted changes included) are copied into the
# container; deps, _build, Hex and Burrito's downloads live in a Docker volume,
# apart from this machine's _build, which another OTP compiled. The version
# the binaries report is the runner's of this checkout (RUNNER_VERSION, else
# `mix runner.version`), the one the control plane built from it requires.
# ------------------------------------------------------------------

OUT="${1:?Usage: build_runner_binaries.sh <output dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${RUNNER_BUILD_IMAGE:-pipemaestro-runner-build}"
CACHE_VOLUME="${RUNNER_BUILD_CACHE:-pipemaestro-runner-build-cache}"

mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"

if [ -z "${RUNNER_VERSION:-}" ]; then
  # Mix may print what it compiles first: the version is the last line.
  RUNNER_VERSION="$(cd "${ROOT}/apps/pipe_maestro_runner" && mix runner.version | tail -n 1)"
fi
echo "==> Runner binaries ${RUNNER_VERSION} (${BURRITO_TARGET:-all targets}) into ${OUT}"

echo "==> Toolchain image ${IMAGE}"
docker build -q -t "${IMAGE}" "${ROOT}/docker/runner-binary" >/dev/null

# Root inside the container, so the cache volume needs no ownership setup;
# the output is handed back to this user at the end.
docker run --rm \
  -v "${ROOT}:/src:ro" \
  -v "${CACHE_VOLUME}:/cache" \
  -v "${OUT}:/out" \
  -e RUNNER_VERSION="${RUNNER_VERSION}" \
  -e BURRITO_TARGET="${BURRITO_TARGET:-}" \
  -e OUT_OWNER="$(id -u):$(id -g)" \
  "${IMAGE}" bash -euo pipefail -c '
    export HOME=/cache/home HEX_HOME=/cache/hex MIX_ENV=prod
    mkdir -p "$HOME" /cache/deps /cache/build
    [ -n "$BURRITO_TARGET" ] || unset BURRITO_TARGET

    tar -C /src -cf - mix.exs mix.lock config apps rel | tar -C /work -xf -
    ln -s /cache/deps /work/deps
    ln -s /cache/build /work/_build

    mix deps.get --only prod
    mix release pipemaestro --overwrite

    rm -f /out/pipemaestro_* /out/SHA256SUMS
    cp burrito_out/pipemaestro_* /out/
    (cd /out && sha256sum pipemaestro_* > SHA256SUMS)
    chmod 0755 /out/pipemaestro_*
    chown "$OUT_OWNER" /out/pipemaestro_* /out/SHA256SUMS
  '

echo "==> Built:"
(cd "${OUT}" && ls -lh pipemaestro_* | awk '{print "    " $5 "  " $NF}')
