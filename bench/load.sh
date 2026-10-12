#!/usr/bin/env bash
# PLAN P5 load measurement (ADR-013): `vllm bench serve` through the real
# gateway, from the release's own vLLM image, at fixed lengths and several
# concurrency levels, repeated, ABBA-alternated by the operator across variants.
#   bench/load.sh --label l40s-1-qwen38 [--runs 5] [--concurrency "1 8 32"]
#                 [--input-len 2048] [--output-len 512] [--prompts-per-level 4]
# Needs: a deployed release, a benchmark key in OPENAI_API_KEY (issue-key.sh
# --alias bench, no limits), the model staged in MODEL_CACHE_DIR (tokenizer).
# Output: $LW_BENCH_DIR/<label>/c<C>-r<N>.json (vLLM's own result format) and
# capacity.txt (the start-up lines that state the KV capacity, AC-3.1).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

: "${LW_BENCH_DIR:=/var/lib/lifewatch/bench}"
LABEL="" RUNS=5 LEVELS="1 8 32" IN_LEN=2048 OUT_LEN=512 PER_LEVEL=4
usage() { die "Usage: $0 --label NAME [--runs N] [--concurrency \"1 8 32\"] [--input-len N] [--output-len N] [--prompts-per-level N]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --concurrency) LEVELS=$2; shift 2 ;;
    --input-len) IN_LEN=$2; shift 2 ;;
    --output-len) OUT_LEN=$2; shift 2 ;;
    --prompts-per-level) PER_LEVEL=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${LABEL}" =~ ^[A-Za-z0-9._-]+$ ]] || usage
for n in "${RUNS}" "${IN_LEN}" "${OUT_LEN}" "${PER_LEVEL}" ${LEVELS}; do
  [[ "${n}" =~ ^[1-9][0-9]*$ ]] || die "not a positive integer: ${n}"
done
[[ -n "${OPENAI_API_KEY:-}" ]] || die "Set OPENAI_API_KEY to a benchmark key (scripts/ops/issue-key.sh --alias bench)"

REL="$(release_dir "$(current_release_id)")"
[[ -d "${REL}" && -n "$(current_release_id)" ]] || die "No deployed release"
R() { env_value "${REL}/release.env" "$1"; }
IMAGE="$(stack_compose "${REL}" config --format json | jq -r '.services["vllm-backend"].image')"
CACHE="$(R MODEL_CACHE_DIR)"
TOKENIZER="/root/.cache/huggingface/hub/models--$(R MODEL_ID | sed 's|/|--|g')/snapshots/$(R MODEL_REVISION)"
OUT="${LW_BENCH_DIR}/${LABEL}"
mkdir -p "${OUT}"
[[ -z "$(ls -A "${OUT}" 2>/dev/null)" ]] || die "${OUT} is not empty; use a new --label"

{
  echo "label=${LABEL}"
  echo "release=$(current_release_id)"
  echo "profile=$(R PROFILE_NAME)"
  echo "model=$(R MODEL_ID)@$(R MODEL_REVISION)"
  echo "max_model_len=$(R VLLM_MAX_MODEL_LEN) max_num_seqs=$(R VLLM_MAX_NUM_SEQS) tp=$(R VLLM_TENSOR_PARALLEL_SIZE)"
  echo "input_len=${IN_LEN} output_len=${OUT_LEN} levels=${LEVELS} runs=${RUNS}"
  echo "started=$(timestamp)"
} >"${OUT}/meta.txt"

# Capacity as vLLM states it at start-up (AC-3.1).
vllm_id="$(container_id vllm-backend)"
if [[ -n "${vllm_id}" ]]; then
  docker logs "${vllm_id}" 2>&1 |
    grep -E 'GPU blocks|KV cache|Maximum concurrency|model weights took|Available KV cache memory' >"${OUT}/capacity.txt" || true
fi

for r in $(seq 1 "${RUNS}"); do
  for c in ${LEVELS}; do
    info "run ${r}/${RUNS}, concurrency ${c}"
    docker run --rm --network host -e OPENAI_API_KEY -e HF_HUB_OFFLINE=1 \
      -v "${CACHE}:/root/.cache/huggingface:ro" -v "${OUT}:/out" \
      --entrypoint vllm "${IMAGE}" bench serve \
      --backend openai-chat --base-url "${LW_GATEWAY_URL}" --endpoint /v1/chat/completions \
      --model "$(R SERVED_MODEL_NAME)" --tokenizer "${TOKENIZER}" \
      --dataset-name random --random-input-len "${IN_LEN}" --random-output-len "${OUT_LEN}" \
      --num-prompts "$((c * PER_LEVEL))" --max-concurrency "${c}" --ignore-eos --seed "${r}" \
      --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,95 \
      --save-result --result-dir /out --result-filename "c${c}-r${r}.json" >"${OUT}/c${c}-r${r}.log" 2>&1 ||
      die "bench failed at concurrency ${c}, run ${r}: see ${OUT}/c${c}-r${r}.log"
  done
done
echo "finished=$(timestamp)" >>"${OUT}/meta.txt"
pass "Results in ${OUT}; summarise with: python3 bench/report.py ${OUT} [baseline-dir]"
