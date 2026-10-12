#!/usr/bin/env bash
# Issue a scoped LiteLLM virtual key (OSS feature) using the master key.
# Prints ONLY the key on stdout so it can be captured; never logs it.
#   issue-key.sh --alias open-webui [--models m1,m2] [--duration 365d] [--max-budget N]
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

ALIAS=""
MODELS="$(env_value "${LW_RELEASE_ENV}" SERVED_MODEL_NAME)"
DURATION=""
BUDGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) ALIAS=$2; shift 2 ;;
    --models) MODELS=$2; shift 2 ;;
    --duration) DURATION=$2; shift 2 ;;
    --max-budget) BUDGET=$2; shift 2 ;;
    *) die "Usage: $0 --alias NAME [--models m1,m2] [--duration 365d] [--max-budget N]" ;;
  esac
done
[[ "${ALIAS}" =~ ^[A-Za-z0-9._-]+$ ]] || die "--alias is required ([A-Za-z0-9._-])"

MASTER="$(env_value "${LW_ENV_FILE}" LITELLM_MASTER_KEY)"
[[ -n "${MASTER}" ]] || die "LITELLM_MASTER_KEY not set in ${LW_ENV_FILE}"

PAYLOAD="$(jq -nc --arg alias "${ALIAS}" --arg models "${MODELS}" --arg dur "${DURATION}" --arg budget "${BUDGET}" '
  {key_alias: $alias, models: ($models | split(",")), metadata: {issued_by: "issue-key.sh"}}
  + (if $dur != "" then {duration: $dur} else {} end)
  + (if $budget != "" then {max_budget: ($budget | tonumber)} else {} end)')"

BODY="$(mktemp)"
trap 'rm -f "${BODY}"' EXIT
code="$(curl -sS -o "${BODY}" -w '%{http_code}' --max-time 30 -X POST \
  -H "Authorization: Bearer ${MASTER}" -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" "${LW_GATEWAY_URL}/key/generate")" || code=000
[[ "${code}" == 200 ]] || die "Key generation failed (HTTP ${code})"
key="$(jq -r '.key // empty' "${BODY}")"
[[ -n "${key}" ]] || die "Gateway response contained no key"
info "Issued key '${ALIAS}' for models: ${MODELS}"
printf '%s\n' "${key}"
