#!/usr/bin/env bash
# Stage the pinned model weights into MODEL_CACHE_DIR so vLLM can run offline
# (it sits on an internal network with no egress and HF_HUB_OFFLINE=1).
# Uses the exact vLLM image of the release, so the huggingface_hub that
# downloads is the one that will read the cache.
#   fetch-model.sh       (reads MODEL_ID / MODEL_REVISION from release.env)
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

: "${LW_MIN_FREE_GB:=100}"

MODEL_ID="$(env_value "${LW_RELEASE_ENV}" MODEL_ID)"
REVISION="$(env_value "${LW_RELEASE_ENV}" MODEL_REVISION)"
CACHE="$(env_value "${LW_RELEASE_ENV}" MODEL_CACHE_DIR)"
[[ "${REVISION}" =~ ^[0-9a-f]{40}$ ]] || die "MODEL_REVISION must be a full 40-char commit sha, got '${REVISION}'"
SNAPSHOT="${CACHE}/hub/models--${MODEL_ID//\//--}/snapshots/${REVISION}"

if [[ -d "${SNAPSHOT}" && -n "$(ls -A "${SNAPSHOT}")" ]]; then
  pass "${MODEL_ID}@${REVISION} already staged"
  exit 0
fi

mkdir -p "${CACHE}"
free_gb="$(df -P --block-size=1G "${CACHE}" | awk 'NR == 2 {print $4}')"
[[ "${free_gb}" -ge "${LW_MIN_FREE_GB}" ]] || die "Only ${free_gb} GB free on ${CACHE}; need ${LW_MIN_FREE_GB} GB"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
snapshot_release "${TMP}"
IMAGE="$(stack_compose "${TMP}" config --format json | jq -r '.services["vllm-backend"].image')"
[[ -n "${IMAGE}" && "${IMAGE}" != null ]] || die "Could not resolve the vLLM image from compose.yaml"

HF_TOKEN="$(env_value "${LW_ENV_FILE}" HF_TOKEN 2>/dev/null || true)"
export HF_TOKEN
info "Downloading ${MODEL_ID}@${REVISION} into ${CACHE}"
docker run --rm -e HF_TOKEN \
  -v "${CACHE}:/root/.cache/huggingface" \
  --entrypoint hf "${IMAGE}" \
  download "${MODEL_ID}" --revision "${REVISION}"

[[ -d "${SNAPSHOT}" && -n "$(ls -A "${SNAPSHOT}")" ]] || die "Download finished but ${SNAPSHOT} is missing or empty"
pass "Staged ${MODEL_ID}@${REVISION}"
