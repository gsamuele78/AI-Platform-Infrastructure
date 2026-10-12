#!/usr/bin/env bash
# Issue a scoped LiteLLM virtual key (OSS feature) using the master key.
# Prints ONLY the key on stdout so it can be captured; never logs it.
#   issue-key.sh --alias NAME [--models m1,m2] [--duration 365d] [--max-budget N]
#                [--rpm N] [--tpm N] [--max-parallel N]
# Budgets are in millions of tokens (configs/proxy/config.yaml prices every
# token at 1e-6). Limits are per key (ADR-014): give agents a low
# --max-parallel so one client cannot hold every GPU slot.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

ALIAS=""
PROFILE_FILE="$(active_release_env)" || die "Could not find the release profile"
MODELS="$(env_value "${PROFILE_FILE}" SERVED_MODEL_NAME)"
DURATION=""
BUDGET=""
RPM=""
TPM=""
PARALLEL=""
usage() { die "Usage: $0 --alias NAME [--models m1,m2] [--duration 365d] [--max-budget MTOKENS] [--rpm N] [--tpm N] [--max-parallel N]"; }
posint() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 needs a positive integer, got '$2'"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) ALIAS=$2; shift 2 ;;
    --models) MODELS=$2; shift 2 ;;
    --duration) DURATION=$2; shift 2 ;;
    --max-budget) BUDGET=$2; shift 2 ;;
    --rpm) posint "$1" "$2"; RPM=$2; shift 2 ;;
    --tpm) posint "$1" "$2"; TPM=$2; shift 2 ;;
    --max-parallel) posint "$1" "$2"; PARALLEL=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${ALIAS}" =~ ^[A-Za-z0-9._-]+$ ]] || die "--alias is required ([A-Za-z0-9._-])"

MASTER="$(env_value "${LW_ENV_FILE}" LITELLM_MASTER_KEY)"
[[ -n "${MASTER}" ]] || die "LITELLM_MASTER_KEY not set in ${LW_ENV_FILE}"

[[ -z "${BUDGET}" || "${BUDGET}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--max-budget needs a number (millions of tokens)"
PAYLOAD="$(jq -nc --arg alias "${ALIAS}" --arg models "${MODELS}" --arg dur "${DURATION}" --arg budget "${BUDGET}" \
  --arg rpm "${RPM}" --arg tpm "${TPM}" --arg par "${PARALLEL}" '
  {key_alias: $alias, models: ($models | split(",")), metadata: {issued_by: "issue-key.sh"}}
  + (if $dur != "" then {duration: $dur} else {} end)
  + (if $budget != "" then {max_budget: ($budget | tonumber)} else {} end)
  + (if $rpm != "" then {rpm_limit: ($rpm | tonumber)} else {} end)
  + (if $tpm != "" then {tpm_limit: ($tpm | tonumber)} else {} end)
  + (if $par != "" then {max_parallel_requests: ($par | tonumber)} else {} end)')"

BODY="$(mktemp)"
trap 'rm -f "${BODY}"' EXIT
code="$(curl -sS -o "${BODY}" -w '%{http_code}' --max-time 30 -X POST \
  -H "Authorization: Bearer ${MASTER}" -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" "${LW_GATEWAY_URL}/key/generate")" || code=000
[[ "${code}" == 200 ]] || die "Key generation failed (HTTP ${code})"
key="$(jq -r '.key // empty' "${BODY}")"
[[ -n "${key}" ]] || die "Gateway response contained no key"
info "Issued key '${ALIAS}' for models: ${MODELS}${RPM:+, rpm ${RPM}}${TPM:+, tpm ${TPM}}${PARALLEL:+, parallel ${PARALLEL}}${BUDGET:+, budget ${BUDGET} Mtokens}"
printf '%s\n' "${key}"
