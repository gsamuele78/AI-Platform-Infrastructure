#!/usr/bin/env bash
# Post-deploy release gate. Every check maps to an acceptance criterion.
#   smoke-test.sh [--release-dir DIR] [--skip-inference]
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

REL_ENV=""
INFERENCE=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir)
      REL_ENV="$2/release.env"
      shift 2
      ;;
    --skip-inference)
      INFERENCE=false
      shift
      ;;
    *) die "Usage: $0 [--release-dir DIR] [--skip-inference]" ;;
  esac
done

[[ -n "${REL_ENV}" ]] || REL_ENV="$(active_release_env)" || die "No release to test (deploy first or pass --release-dir)"
MODEL="$(env_value "${REL_ENV}" SERVED_MODEL_NAME)"
MASTER="$(env_value "${LW_ENV_FILE}" LITELLM_MASTER_KEY)"
BODY="$(mktemp)"
trap 'rm -f "${BODY}"' EXIT
errors=0

# http METHOD URL [KEY] [JSON] [CURL_ARGS...]: prints the HTTP status, body in $BODY.
http() {
  local args=(-sS -o "${BODY}" -w '%{http_code}' --max-time 120 -X "$1") url=$2
  [[ -n "${3:-}" ]] && args+=(-H "Authorization: Bearer $3")
  [[ -n "${4:-}" ]] && args+=(-H 'Content-Type: application/json' -d "$4")
  args+=("${@:5}")
  curl "${args[@]}" "${url}" 2>/dev/null || true
}

# https_ingress METHOD PORT PATH [KEY] [JSON]: request through the ingress using
# the PUBLIC hostname (pinned to loopback), verifying the certificate chain and
# name exactly as a client would.
HOST="$(env_value "${LW_ENV_FILE}" PUBLIC_HOSTNAME)"
TLS_LIVE="$(env_value "${LW_ENV_FILE}" TLS_DIR)/live"
CA="${LW_TLS_CA_FILE:-}"
if [[ -z "${CA}" && "$(cat "${TLS_LIVE}/mode" 2>/dev/null)" == self-signed ]]; then CA="${TLS_LIVE}/ca.pem"; fi
port() { local v; v="$(env_value "${LW_ENV_FILE}" "$1")"; echo "${v:-$2}"; }
HTTP_PORT="$(port INGRESS_HTTP_PORT 80)"
HTTPS_PORT="$(port INGRESS_HTTPS_PORT 443)"
API_PORT="$(port INGRESS_API_PORT 8443)"
https_ingress() {
  local extra=(--resolve "${HOST}:$2:127.0.0.1")
  [[ -n "${CA}" ]] && extra+=(--cacert "${CA}")
  http "$1" "https://${HOST}:$2$3" "${4:-}" "${5:-}" "${extra[@]}"
}

check() { # check DESCRIPTION EXPECTED ACTUAL
  if [[ "$3" == "$2" ]]; then
    pass "$1 (HTTP $3)"
  else
    fail "$1: expected HTTP $2, got ${3:-none}"
    errors=$((errors + 1))
  fi
}

CHAT="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}"

check "Gateway liveness" 200 "$(http GET "${LW_GATEWAY_URL}/health/liveliness")"
check "Unauthenticated request is rejected" 401 "$(http POST "${LW_GATEWAY_URL}/v1/chat/completions" "" "${CHAT}")"
check "Invalid key is rejected" 401 "$(http POST "${LW_GATEWAY_URL}/v1/chat/completions" "sk-invalid-smoke-test" "${CHAT}")"

code="$(http GET "${LW_GATEWAY_URL}/v1/models" "${MASTER}")"
if [[ "${code}" == 200 ]] && jq -e --arg m "${MODEL}" '.data | map(.id) | index($m)' "${BODY}" >/dev/null 2>&1; then
  pass "Model ${MODEL} is served"
else
  fail "Model ${MODEL} not listed by /v1/models (HTTP ${code})"
  errors=$((errors + 1))
fi

if [[ "${INFERENCE}" == true ]]; then
  check "End-to-end inference through gateway to vLLM" 200 "$(http POST "${LW_GATEWAY_URL}/v1/chat/completions" "${MASTER}" "${CHAT}")"

  # ADR-014: agents send tools with tool_choice=auto. vLLM rejects that unless
  # auto tool choice is on (R3-02), so HTTP 200 is the regression check; any
  # call the model makes must name the offered tool with JSON-object arguments.
  # Whether the model *chooses* tools well is measured in PLAN P5, not here.
  TOOLS="$(jq -nc --arg m "${MODEL}" '{model: $m, max_tokens: 256,
    messages: [{role: "user", content: "What is the current UTC time? Use the tool."}],
    tools: [{type: "function", function: {name: "get_utc_time", description: "Current UTC time",
      parameters: {type: "object", properties: {}}}}], tool_choice: "auto"}')"
  code="$(http POST "${LW_GATEWAY_URL}/v1/chat/completions" "${MASTER}" "${TOOLS}")"
  if [[ "${code}" == 200 ]] && jq -e '(.choices[0].message.tool_calls // [])
      | all(.function.name == "get_utc_time" and ((.function.arguments // "{}") | fromjson | type == "object"))' \
      "${BODY}" >/dev/null 2>&1; then
    pass "Tool calling accepted with tool_choice=auto ($(jq '.choices[0].message.tool_calls // [] | length' "${BODY}") well-formed call(s)) (HTTP 200)"
  else
    fail "Tool calling (tool_choice=auto): HTTP ${code}, or a malformed tool call; check --enable-auto-tool-choice and the profile's VLLM_TOOL_CALL_PARSER"
    errors=$((errors + 1))
  fi
fi

check "Open WebUI health" 200 "$(http GET "${LW_WEBUI_HEALTH_URL}")"

check "Ingress health" 200 "$(http GET "http://127.0.0.1:${HTTP_PORT}/healthz")"
check "Ingress HTTP redirects to HTTPS" 301 "$(http GET "http://127.0.0.1:${HTTP_PORT}/")"
check "Open WebUI over TLS as https://${HOST}" 200 "$(https_ingress GET "${HTTPS_PORT}" /health)"
check "Public API rejects unauthenticated requests" 401 "$(https_ingress POST "${API_PORT}" /v1/chat/completions "" "${CHAT}")"
check "Gateway admin API is not exposed publicly" 404 "$(https_ingress POST "${API_PORT}" /key/generate "${MASTER}" '{}')"

[[ "${errors}" -eq 0 ]] || die "Smoke test failed (${errors} check(s))"
pass "Smoke test passed"
