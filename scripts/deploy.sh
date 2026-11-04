#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# PipeMaestro — build and publish on the server, through DeployEx
#
# Usage:  bash deploy.sh <git-ref>
#
# Runs ON the server (Sun), started by `make deploy` (scripts/deploy_sun.sh).
# The server's clone (~/pipemaestro, from the Forgejo, made by the infra's
# app_clone role) is aligned with origin/<ref>; the release is built there,
# its tarball goes to DeployEx's dist directory, and current.json tells
# DeployEx to roll it out, migrating the database first.
#
# The last line printed is `RELEASE=<version>`: the release /version will
# answer once DeployEx has it serving.
# ------------------------------------------------------------------

APP_NAME="pipe_maestro"
SOURCE_DIR="$HOME/pipemaestro"
DIST_DIR="$HOME/releases/dist/${APP_NAME}"
VERSIONS_DIR="$HOME/releases/versions/${APP_NAME}/local"
KEEP_RELEASES=3

GIT_REF="${1:?Usage: deploy.sh <git-ref>}"

# DeployEx runs as another user and reads what this script writes; the
# server's umask would leave new directories closed to it.
umask 022

echo "==> Deploy of ${APP_NAME} @ ${GIT_REF}"

# ------------------------------------------------------------------
# 0. A full disk fails inside DeployEx, after this script reported
#    success; stop here instead, naming the cause.
# ------------------------------------------------------------------
MIN_FREE_GB="${DEPLOY_MIN_FREE_GB:-3}"
FREE_KB=$(df -Pk "${HOME}" | awk 'NR==2 {print $4}')
if [ "${FREE_KB}" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
  echo "ERROR: only $((FREE_KB / 1024)) MB free; a deploy needs ${MIN_FREE_GB} GB." >&2
  exit 1
fi
echo "==> Disk: $((FREE_KB / 1024 / 1024)) GB free"

# ------------------------------------------------------------------
# 1. Align the clone with origin/<ref> (survives force-pushes)
# ------------------------------------------------------------------
cd "${SOURCE_DIR}"
git fetch --all --prune --tags
git checkout "${GIT_REF}" --
git reset --hard "origin/${GIT_REF}"
# Generated assets are rebuilt below; nothing stale may reach the release.
git clean -fdx -- apps/pipe_maestro_web/priv/static/

FULL_SHA=$(git rev-parse HEAD)
SHORT_SHA=$(git rev-parse --short HEAD)
# A SemVer pre-release made only of digits may not start with a zero.
SHA_LENGTH=${#SHORT_SHA}
while [[ "${SHORT_SHA}" =~ ^0[0-9]*$ && ${SHA_LENGTH} -lt 40 ]]; do
  SHA_LENGTH=$((SHA_LENGTH + 1))
  SHORT_SHA=$(git rev-parse --short=${SHA_LENGTH} HEAD)
done
MIX_VERSION=$(grep 'version: "' mix.exs | head -1 | sed 's/.*"\(.*\)".*/\1/')
RELEASE_VERSION="${MIX_VERSION}-${SHORT_SHA}"
echo "==> Release ${RELEASE_VERSION} (${FULL_SHA})"

# ------------------------------------------------------------------
# 2. Stamp the commit on the release (the tarball's name) and on the
#    domain app, whose vsn /version reports. Restored on exit.
# ------------------------------------------------------------------
STAMPED=(mix.exs apps/pipe_maestro/mix.exs)
for file in "${STAMPED[@]}"; do
  sed -i.bak "s/version: \"${MIX_VERSION}\"/version: \"${RELEASE_VERSION}\"/" "${file}"
done

cleanup() {
  for file in "${STAMPED[@]}"; do
    mv "${file}.bak" "${file}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ------------------------------------------------------------------
# 3. Build. Tailwind and esbuild are standalone binaries: no npm.
# ------------------------------------------------------------------
# shellcheck disable=SC1091
source "$HOME/.asdf/asdf.sh" 2>/dev/null || source /opt/asdf-vm/asdf.sh 2>/dev/null || true

export MIX_ENV=prod
# The build shares the host with the running apps: two schedulers, no busy wait.
DEPLOY_ERL_SCHEDULERS="${DEPLOY_ERL_SCHEDULERS:-2}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+S ${DEPLOY_ERL_SCHEDULERS}:${DEPLOY_ERL_SCHEDULERS} +sbwt none +sbwtdcpu none +sbwtdio none}"

# A build from another Erlang/Elixir is not reused.
TOOLCHAIN_MARK="_build/prod/.toolchain"
if [ "$(cat "${TOOLCHAIN_MARK}" 2>/dev/null)" != "$(cat .tool-versions)" ]; then
  echo "==> Erlang/Elixir changed since the last build: building from scratch"
  rm -rf _build/prod deps
fi

mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --only prod
mix deps.clean --unused
mix compile
mix assets.deploy
mix release "${APP_NAME}" --overwrite
mkdir -p _build/prod
cp .tool-versions "${TOOLCHAIN_MARK}"

TARBALL="_build/prod/${APP_NAME}-${RELEASE_VERSION}.tar.gz"
if [ ! -f "${TARBALL}" ]; then
  echo "ERROR: tarball not found at ${TARBALL}" >&2
  ls -la _build/prod/*.tar.gz 2>/dev/null || true
  exit 1
fi

# ------------------------------------------------------------------
# 4. Hand it to DeployEx
# ------------------------------------------------------------------
mkdir -p "${DIST_DIR}" "${VERSIONS_DIR}"
cp "${TARBALL}" "${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.tar.gz"

CURRENT_JSON="${VERSIONS_DIR}/current.json"
cat > "${CURRENT_JSON}" <<EOF
{
  "version": "${RELEASE_VERSION}",
  "hash": "${FULL_SHA}",
  "pre_commands": ["eval PipeMaestro.Release.migrate"]
}
EOF

# DeployEx runs as its own user and reads what the deploy user wrote.
chmod o+rx "${DIST_DIR}" "${VERSIONS_DIR}"
chmod o+r "${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.tar.gz" "${CURRENT_JSON}"

# ------------------------------------------------------------------
# 5. Keep the disk in check
# ------------------------------------------------------------------
# shellcheck disable=SC2012
ls -t "${DIST_DIR}"/*.tar.gz 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -f
# DeployEx runs its own unpacked copy; the assembled tree only fed the tarball.
rm -rf "${SOURCE_DIR}/_build/prod/rel/${APP_NAME}"
# shellcheck disable=SC2012
ls -t "${SOURCE_DIR}/_build/prod/"*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -f

echo "==> Disk after cleanup: $(df -Ph "${HOME}" | awk 'NR==2 {print $4}') free"
echo "==> Handed to DeployEx: ${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.tar.gz"
echo "RELEASE=${RELEASE_VERSION}"
