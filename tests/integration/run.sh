#!/usr/bin/env bash
# End-to-end lifecycle against REAL containers (gateway, UI, Postgres, nginx
# ingress, certbot) with a fake GPU backend. Requires Docker; no GPU.
#   0. TLS phase 1: self-signed lab CA
#   1-5. deploy -> scoped key -> redeploy -> broken release auto-rolls back -> manual rollback
#   6. TLS phase 2: real ACME HTTP-01 issuance + renewal via certbot against
#      Pebble, Let's Encrypt's official test CA
# Env: LW_TEST_BACKUP_DIR=<mountpoint> to require backups on a dedicated mount.
#      LW_TEST_UNPRIVILEGED_PORTS=1 for rootless engines (ingress on 8081/8444/8445).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
export LW_PROJECT=lwci
export LW_STATE_DIR="${WORK}/state"
export LW_ENV_FILE="${WORK}/ci.env"
export LW_WAIT_TIMEOUT=900
export LW_COMPOSE_OVERRIDES=tests/integration/compose.fake-vllm.yaml
PEBBLE_IMAGE="ghcr.io/letsencrypt/pebble:2.10.1@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199"
PY_IMAGE="python:3.12-alpine@sha256:1b668429b3511ab407d8e00648891631b0b1a4d7e15e3ca70f38ab5b91ad4ab4"
NET="${LW_PROJECT}_frontend-net"

BACKUP_DIR="${LW_TEST_BACKUP_DIR:-${WORK}/backups}"
mkdir -p "${BACKUP_DIR}"
install -m 600 "${REPO}/tests/integration/ci.env" "${LW_ENV_FILE}"
sed -i -e "s|^TLS_DIR=.*|TLS_DIR=${WORK}/tls|" -e "s|^BACKUP_DIR=.*|BACKUP_DIR=${BACKUP_DIR}|" "${LW_ENV_FILE}"
if [[ -n "${LW_TEST_BACKUP_DIR:-}" ]]; then sed -i 's|^BACKUP_REQUIRE_MOUNT=.*|BACKUP_REQUIRE_MOUNT=true|' "${LW_ENV_FILE}"; fi
# Rootless engines (Podman) cannot bind ports < 1024.
if [[ "${LW_TEST_UNPRIVILEGED_PORTS:-0}" == 1 ]]; then
  sed -i 's|^WEBUI_URL=.*|WEBUI_URL=https://lifewatch.test:8444|' "${LW_ENV_FILE}"
  printf 'INGRESS_HTTP_PORT=8081\nINGRESS_HTTPS_PORT=8444\nINGRESS_API_PORT=8445\nINGRESS_REDIRECT_AUTHORITY=lifewatch.test:8444\n' >>"${LW_ENV_FILE}"
fi

step() { printf '\n=== %s\n' "$*" >&2; }
current() { basename "$(readlink -f "${LW_STATE_DIR}/releases/current")"; }
deploy() { bash "${REPO}/scripts/deploy/deploy.sh" --allow-dirty --skip gpu,model; }
# net_fetch URL: GET from inside the project network, ignoring the test CA's TLS.
net_fetch() {
  docker run --rm --network "${NET}" "${PY_IMAGE}" python3 -c '
import ssl, sys, time, urllib.request
ctx = ssl._create_unverified_context()
for _ in range(30):
    try:
        sys.stdout.write(urllib.request.urlopen(sys.argv[1], context=ctx, timeout=5).read().decode()); break
    except Exception:
        time.sleep(1)
else:
    sys.exit(1)' "$1"
}

cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    docker compose -p "${LW_PROJECT}" ps -a || true
    docker compose -p "${LW_PROJECT}" logs --no-color --tail 80 || true
    docker logs --tail 50 lwci-pebble 2>/dev/null || true
  fi
  docker rm -f lwci-pebble >/dev/null 2>&1 || true
  docker ps -aq --filter "label=com.docker.compose.project=${LW_PROJECT}" | xargs -r docker rm -f >/dev/null
  docker volume ls -q --filter "label=com.docker.compose.project=${LW_PROJECT}" | xargs -r docker volume rm >/dev/null
  docker network ls -q --filter "label=com.docker.compose.project=${LW_PROJECT}" | xargs -r docker network rm >/dev/null
  rm -rf "${WORK}"
  if [[ -n "${LW_TEST_BACKUP_DIR:-}" ]]; then find "${LW_TEST_BACKUP_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi
  exit "${rc}"
}
trap cleanup EXIT

step "0. TLS phase 1: self-signed certificate from a lab CA"
bash "${REPO}/scripts/ops/tls-selfsigned.sh"

step "1. First deploy (smoke test covers the TLS ingress)"
deploy
FIRST="$(current)"

step "2. Unauthenticated access is refused by the real gateway"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:4000/v1/chat/completions \
  -H 'Content-Type: application/json' -d '{"model":"lifewatch-chat","messages":[]}')"
[[ "${code}" == 401 ]] || { echo "expected 401, got ${code}" >&2; exit 1; }

step "3. Issue a scoped key for Open WebUI and redeploy (backup lands in BACKUP_DIR)"
key="$(bash "${REPO}/scripts/ops/issue-key.sh" --alias open-webui)"
[[ "${key}" == sk-* ]]
sed -i "s|^OPENWEBUI_API_KEY=.*|OPENWEBUI_API_KEY=${key}|" "${LW_ENV_FILE}"
sleep 1
deploy
SECOND="$(current)"
[[ "${SECOND}" != "${FIRST}" ]]
[[ -n "$(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -name SHA256SUMS)" ]]
[[ -n "$(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -name tls.tgz)" ]]

step "4. A release that never becomes healthy is rolled back automatically"
sleep 1
if LW_WAIT_TIMEOUT=120 LW_COMPOSE_OVERRIDES="${LW_COMPOSE_OVERRIDES} tests/integration/compose.broken.yaml" deploy; then
  echo "broken release was accepted" >&2
  exit 1
fi
[[ "$(current)" == "${SECOND}" ]]
bash "${REPO}/scripts/deploy/smoke-test.sh" --release-dir "${LW_STATE_DIR}/releases/${SECOND}"

step "5. Manual rollback to the previous release"
bash "${REPO}/scripts/deploy/rollback.sh" --previous --no-restore --yes
[[ "$(current)" == "${FIRST}" ]]

step "6. TLS phase 2: ACME HTTP-01 issuance through the ingress (certbot -> Pebble)"
docker run -d --name lwci-pebble --network "${NET}" \
  -e PEBBLE_VA_NOSLEEP=1 -e PEBBLE_WFE_NONCEREJECT=0 \
  -v "${REPO}/tests/integration/pebble-config.json:/test/config/pebble-config.json:ro" \
  "${PEBBLE_IMAGE}" -config /test/config/pebble-config.json >/dev/null
net_fetch https://lwci-pebble:14000/dir >/dev/null
bash "${REPO}/scripts/ops/tls-letsencrypt.sh" --email ops@lifewatch.test \
  --server https://lwci-pebble:14000/dir --no-verify-ssl
TLS_LIVE="${WORK}/tls/live"
[[ "$(cat "${TLS_LIVE}/mode")" == letsencrypt ]]
net_fetch https://lwci-pebble:15000/roots/0 >"${WORK}/pebble-root.pem"
openssl verify -CAfile "${WORK}/pebble-root.pem" -untrusted "${TLS_LIVE}/fullchain.pem" "${TLS_LIVE}/fullchain.pem"
LW_TLS_CA_FILE="${WORK}/pebble-root.pem" bash "${REPO}/scripts/deploy/smoke-test.sh" --release-dir "${LW_STATE_DIR}/releases/${FIRST}"

step "7. Renewal is a no-op when not due; self-signed cannot silently replace Let's Encrypt"
bash "${REPO}/scripts/ops/tls-letsencrypt.sh" --renew --no-verify-ssl 2>&1 | tee "${WORK}/renew.log"
grep -q "unchanged" "${WORK}/renew.log"
if bash "${REPO}/scripts/ops/tls-selfsigned.sh" 2>/dev/null; then
  echo "self-signed overwrote the Let's Encrypt certificate" >&2
  exit 1
fi

step "Integration lifecycle passed"
