#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# PipeMaestro — publish a ref on Sun and wait until it serves
#
# Usage:  scripts/deploy_sun.sh <git-ref>     (make deploy / make deploy.skip-ci)
#
# Needs DEPLOY_USER and SUN_IP (from .env, see .env.example); SSH_PORT
# defaults to 2222 and DEPLOY_URL to https://pipemaestro.app.
#
# Asks the server to deploy <ref> through ~/bin/pipemaestro-deploy (the
# infra's deploy_access role): it fetches the server's clone and runs that
# ref's scripts/deploy.sh, one deploy at a time, which builds the release and
# hands it to DeployEx. Then polls DEPLOY_URL/version until the release it
# built is the one answering. The server clones from the Forgejo, so <ref>
# must be pushed first.
#
# Runs on merges to main from the Forgejo (.forgejo/workflows/deploy.yml),
# whose SSH key the server forces to that same script, and by hand with
# `make deploy`.
# ------------------------------------------------------------------

REF="${1:?Usage: deploy_sun.sh <git-ref>}"
: "${DEPLOY_USER:?DEPLOY_USER is required (see .env.example)}"
: "${SUN_IP:?SUN_IP is required (see .env.example)}"
SSH_PORT="${SSH_PORT:-2222}"
DEPLOY_URL="${DEPLOY_URL:-https://pipemaestro.app}"
ROLLOUT_TIMEOUT_S="${ROLLOUT_TIMEOUT_S:-300}"

LOG="$(mktemp "${TMPDIR:-/tmp}/pipemaestro-deploy.XXXXXX")"
trap 'rm -f "${LOG}"' EXIT

if [ -z "$(git ls-remote origin "refs/heads/${REF}" "refs/tags/${REF}" 2>/dev/null)" ]; then
  echo "ERROR: ${REF} is not on origin; push it first (the server fetches from there)." >&2
  exit 1
fi

echo "==> Building ${REF} on Sun (${DEPLOY_USER}@${SUN_IP}:${SSH_PORT})"
ssh -p "${SSH_PORT}" "${DEPLOY_USER}@${SUN_IP}" "~/bin/pipemaestro-deploy deploy ${REF}" | tee "${LOG}"

RELEASE="$(sed -n 's/^RELEASE=//p' "${LOG}" | tail -n 1)"
if [ -z "${RELEASE}" ]; then
  echo "ERROR: the server did not report the release it built." >&2
  exit 1
fi

echo "==> Waiting for ${DEPLOY_URL}/version to answer ${RELEASE} (up to ${ROLLOUT_TIMEOUT_S}s)"
deadline=$(($(date +%s) + ROLLOUT_TIMEOUT_S))
seen=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  seen="$(curl -fsS --max-time 5 "${DEPLOY_URL}/version" 2>/dev/null || true)"
  if [[ "${seen}" == *"\"release\":\"${RELEASE}\""* ]]; then
    echo "==> Live: ${seen}"
    exit 0
  fi
  sleep 5
done

echo "ERROR: ${RELEASE} was not serving after ${ROLLOUT_TIMEOUT_S}s; last answer: ${seen:-none}." >&2
echo "       Check the DeployEx dashboard and the app log (make logs-pipemaestro in the infra)." >&2
exit 1
