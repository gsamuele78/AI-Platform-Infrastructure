#!/usr/bin/env bash
# Lab acceptance on ONE real NVIDIA GPU (e.g. a laptop RTX A2000, 4 GB):
# the production images and scripts end to end, with real vLLM inference on
# Qwen3.5-0.8B (profiles/lab.env) instead of the production model.
#   tests/lab/run-gpu.sh [--keep]
# Engine: rootless Podman by default (a dedicated service with its own storage
# under LAB_DIR, see podman-service.sh; your normal Podman is not touched), or
# the Docker daemon with LW_LAB_ENGINE=docker.
# --keep leaves the stack running: https://localhost:8444 (CA: LAB_DIR/tls/live/ca.pem)
# Prerequisites are checked first (tests/lab/setup.sh); fix them once with
# `sudo make lab-setup`, then run this WITHOUT sudo (docs/operations/LAB.md).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEEP=false
[[ "${1:-}" == --keep ]] && KEEP=true

export LAB_DIR="${LAB_DIR:-/srv/lifewatch-lab}"
ENGINE="${LW_LAB_ENGINE:-podman}"
if [[ "${ENGINE}" == podman && "$(id -u)" -eq 0 ]]; then
  echo "The lab runs rootless: run 'make lab-gpu' WITHOUT sudo (one-time root setup: sudo make lab-setup)" >&2
  exit 2
fi

printf '\n=== [0/7] Prerequisites (tests/lab/setup.sh)\n' >&2
bash "${REPO}/tests/lab/setup.sh" || {
  echo "Prerequisites missing: see the list above. Fix with: sudo make lab-setup (then run make lab-gpu again)" >&2
  exit 1
}
case "${ENGINE}" in
  podman)
    bash "${REPO}/tests/lab/podman-service.sh" start
    eval "$(bash "${REPO}/tests/lab/podman-service.sh" env)"
    export LW_COMPOSE_OVERRIDES=tests/lab/compose.podman-gpu.yaml
    export LW_GPU_DEVICE_ARGS="--device nvidia.com/gpu=all"
    ;;
  docker) docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable" >&2; exit 1; } ;;
  *) echo "LW_LAB_ENGINE must be podman or docker" >&2; exit 2 ;;
esac

export LW_PROJECT=lwlab
export LW_STATE_DIR="${LAB_DIR}/state"
export LW_ENV_FILE="${LAB_DIR}/lab.env"
export LW_RELEASE_ENV="${LAB_DIR}/lab-profile.env"
export LW_WAIT_TIMEOUT=1200
sed "s|^MODEL_CACHE_DIR=.*|MODEL_CACHE_DIR=${LAB_DIR}/vllm_cache|" "${REPO}/profiles/lab.env" >"${LW_RELEASE_ENV}"
install -m 600 "${REPO}/tests/lab/lab.env" "${LW_ENV_FILE}"
sed -i -e "s|^TLS_DIR=.*|TLS_DIR=${LAB_DIR}/tls|" -e "s|^BACKUP_DIR=.*|BACKUP_DIR=${LAB_DIR}/backups|" "${LW_ENV_FILE}"
mkdir -p "${LAB_DIR}/backups" "${LAB_DIR}/vllm_cache"
chmod 0700 "${LAB_DIR}"
API="https://localhost:$(grep '^INGRESS_API_PORT=' "${LW_ENV_FILE}" | cut -d= -f2)"

STEP=0
step() { STEP=$((STEP + 1)); printf '\n=== [%d/7] %s (%s)\n' "${STEP}" "$*" "$(date +%H:%M:%S)" >&2; }
current() { basename "$(readlink -f "${LW_STATE_DIR}/releases/current")"; }

teardown() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    docker compose -p "${LW_PROJECT}" ps -a || true
    docker compose -p "${LW_PROJECT}" logs --no-color --tail 120 || true
  fi
  if [[ "${KEEP}" == true && "${rc}" -eq 0 ]]; then
    echo "Stack left running. UI: https://localhost:8444  API: ${API}/v1  CA: ${LAB_DIR}/tls/live/ca.pem" >&2
    echo "Stop: DOCKER_HOST=${DOCKER_HOST:-} docker compose -p ${LW_PROJECT} down; tests/lab/podman-service.sh stop" >&2
    exit 0
  fi
  docker ps -aq --filter "label=com.docker.compose.project=${LW_PROJECT}" | xargs -r docker rm -f >/dev/null
  docker volume ls -q --filter "label=com.docker.compose.project=${LW_PROJECT}" | xargs -r docker volume rm >/dev/null
  docker network ls -q --filter "label=com.docker.compose.project=${LW_PROJECT}" | xargs -r docker network rm >/dev/null
  rm -rf "${LW_STATE_DIR}" "${LAB_DIR}/backups"
  if [[ "${ENGINE}" == podman ]]; then bash "${REPO}/tests/lab/podman-service.sh" stop; fi
  exit "${rc}"
}
trap teardown EXIT

step "GPU visible on the host and inside containers (CUDA 13 image = driver new enough)"
LW_EXPECTED_GPUS=1 LW_MIN_GPU_MIB=4000 bash "${REPO}/scripts/verify/vm-check.sh"

step "Stage the lab model at its pinned revision (1.75 GB, cached in LAB_DIR across runs)"
LW_MIN_FREE_GB=5 bash "${REPO}/scripts/vm/fetch-model.sh"

step "TLS phase 1 (self-signed lab CA, reused across runs)"
bash "${REPO}/scripts/ops/tls-selfsigned.sh"

step "Deploy with real vLLM; the smoke test includes end-to-end inference"
bash "${REPO}/scripts/deploy/deploy.sh" --allow-dirty
FIRST="$(current)"

step "A real completion through the TLS ingress"
master="$(grep '^LITELLM_MASTER_KEY=' "${LW_ENV_FILE}" | cut -d= -f2)"
curl -sS --fail --cacert "${LAB_DIR}/tls/live/ca.pem" "${API}/v1/chat/completions" \
  -H "Authorization: Bearer ${master}" -H 'Content-Type: application/json' \
  -d '{"model":"lifewatch-chat","max_tokens":40,"messages":[{"role":"user","content":"Name one European research infrastructure for biodiversity."}]}' |
  jq -r '.choices[0].message.content' >&2

step "Scoped key for Open WebUI, redeploy (pre-deploy backup), rollback"
key="$(bash "${REPO}/scripts/ops/issue-key.sh" --alias open-webui)"
sed -i "s|^OPENWEBUI_API_KEY=.*|OPENWEBUI_API_KEY=${key}|" "${LW_ENV_FILE}"
sleep 1
bash "${REPO}/scripts/deploy/deploy.sh" --allow-dirty
[[ -n "$(find "${LAB_DIR}/backups" -mindepth 2 -maxdepth 2 -name SHA256SUMS)" ]]
bash "${REPO}/scripts/deploy/rollback.sh" --previous --no-restore --yes
[[ "$(current)" == "${FIRST}" ]]

step "vLLM capacity report (record it in the release notes)"
docker compose -p "${LW_PROJECT}" logs --no-color vllm-backend 2>&1 |
  grep -Ei 'KV cache|Maximum concurrency|model weights took|memory' | tail -6 >&2 || true

printf '\n=== Lab GPU acceptance passed (%s)\n' "$(date +%H:%M:%S)" >&2
