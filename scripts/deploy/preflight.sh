#!/usr/bin/env bash
# Release preflight on the guest VM: secrets, config, model weights, GPUs.
#   preflight.sh [--release-dir DIR] [--skip gpu,model,tls]
# Without --release-dir the working tree is checked. Exit 1 on any failure.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"
# shellcheck source=scripts/lib/tls.sh
source "${LW_REPO_ROOT}/scripts/lib/tls.sh"

REL=""
SKIP=","
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir)
      REL=$2
      shift 2
      ;;
    --skip)
      SKIP=",$2,"
      shift 2
      ;;
    *) die "Usage: $0 [--release-dir DIR] [--skip gpu,model]" ;;
  esac
done
skipped() { [[ "${SKIP}" == *",$1,"* ]]; }

if [[ -z "${REL}" ]]; then
  REL="$(mktemp -d)"
  trap 'rm -rf "${REL}"' EXIT
  snapshot_release "${REL}" || die "Could not select a GPU profile (ADR-012)"
fi

errors=0
bad() {
  fail "$@"
  errors=$((errors + 1))
}

# ---- Secrets file -----------------------------------------------------------
[[ -f "${LW_ENV_FILE}" ]] || die "Env file ${LW_ENV_FILE} not found (copy .env.example)"
mode="$(stat -c %a "${LW_ENV_FILE}")"
[[ "${mode}" == 600 || "${mode}" == 400 ]] || bad "${LW_ENV_FILE} has mode ${mode}; secrets require 600 (chmod 600 ${LW_ENV_FILE})"

E() { env_value "${LW_ENV_FILE}" "$1"; }
for key in LITELLM_MASTER_KEY VLLM_API_KEY POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
  WEBUI_SECRET_KEY WEBUI_URL OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_DISCOVERY_URL \
  PUBLIC_HOSTNAME TLS_DIR BACKUP_DIR; do
  v="$(E "${key}")"
  if [[ -z "${v}" ]]; then
    bad "${key} is empty"
  elif [[ "${v}" == *CHANGE_ME* ]]; then
    bad "${key} still contains the CHANGE_ME placeholder"
  fi
done

master="$(E LITELLM_MASTER_KEY)"
[[ "${master}" == sk-* ]] || bad "LITELLM_MASTER_KEY must start with 'sk-' (LiteLLM requirement)"
[[ "${#master}" -ge 32 ]] || bad "LITELLM_MASTER_KEY is shorter than 32 characters"
for key in VLLM_API_KEY WEBUI_SECRET_KEY; do
  [[ "$(E "${key}" | wc -c)" -gt 32 ]] || bad "${key} is shorter than 32 characters"
done
pw="$(E POSTGRES_PASSWORD)"
[[ "${pw}" =~ ^[A-Za-z0-9._~-]{16,}$ ]] || bad "POSTGRES_PASSWORD must be >=16 URL-safe characters [A-Za-z0-9._~-] (it is embedded in DATABASE_URL)"
[[ "$(E OIDC_DISCOVERY_URL)" == https://*/.well-known/openid-configuration ]] ||
  bad "OIDC_DISCOVERY_URL must be the https .../.well-known/openid-configuration URL"

webui_key="$(E OPENWEBUI_API_KEY)"
if [[ -z "${webui_key}" ]]; then
  warn "OPENWEBUI_API_KEY is empty: Open WebUI will start but cannot call models. Issue one with scripts/ops/issue-key.sh --alias open-webui"
elif [[ "${webui_key}" == "${master}" ]]; then
  bad "OPENWEBUI_API_KEY must be a scoped virtual key, not the LiteLLM master key"
fi

host="$(E PUBLIC_HOSTNAME)"
valid_hostname "${host}" || bad "PUBLIC_HOSTNAME '${host}' is not a valid DNS name"
[[ "$(E WEBUI_URL)" =~ ^https://${host//./\.}(:[0-9]+)?/?$ ]] ||
  warn "WEBUI_URL ($(E WEBUI_URL)) is not https://${host}: OIDC redirects and CORS will not match the ingress"

# ---- TLS ----------------------------------------------------------------------
if ! skipped tls; then
  live="$(E TLS_DIR)/live"
  if [[ ! -f "${live}/fullchain.pem" || ! -f "${live}/privkey.pem" ]]; then
    bad "No certificate in ${live}; run scripts/ops/tls-selfsigned.sh (phase 1) or scripts/ops/tls-letsencrypt.sh"
  else
    cert_covers "${live}/fullchain.pem" "${host}" || bad "Certificate in ${live} does not cover ${host}; re-run scripts/ops/tls-selfsigned.sh"
    key_matches "${live}/fullchain.pem" "${live}/privkey.pem" || bad "Private key in ${live} does not match the certificate"
    if ! cert_valid_for "${live}/fullchain.pem" 0; then
      bad "Certificate in ${live} has expired"
    elif ! cert_valid_for "${live}/fullchain.pem" 1209600; then
      warn "Certificate in ${live} will expire within 14 days"
    else
      pass "TLS certificate ($(cat "${live}/mode" 2>/dev/null || echo unknown)) valid for ${host}"
    fi
  fi
fi

# ---- Backups -------------------------------------------------------------------
backup_dir_checks || errors=$((errors + 1))

# ---- Compose model ----------------------------------------------------------
if compose_err="$(stack_compose "${REL}" config -q 2>&1)"; then
  pass "Compose configuration renders"
else
  bad "Compose configuration does not render: ${compose_err}"
fi

# ---- Model weights (vLLM runs offline) --------------------------------------
if ! skipped model; then
  R() { env_value "${REL}/release.env" "$1"; }
  model_id="$(R MODEL_ID)"
  snapshot="$(R MODEL_CACHE_DIR)/hub/models--${model_id//\//--}/snapshots/$(R MODEL_REVISION)"
  if [[ -d "${snapshot}" && -n "$(ls -A "${snapshot}" 2>/dev/null)" ]]; then
    pass "Model ${model_id}@$(R MODEL_REVISION) staged"
  else
    bad "Model ${model_id}@$(R MODEL_REVISION) not found at ${snapshot}; run scripts/vm/fetch-model.sh"
  fi
fi

# ---- Profile (ADR-012) ----------------------------------------------------------
P() { env_value "${REL}/release.env" "$1"; }
profile="$(P PROFILE_NAME)"
case "$(P PROFILE_STATUS)" in
  validated | lab) pass "Profile ${profile:-?} ($(P PROFILE_STATUS)): $(P MODEL_ID)" ;;
  *)
    if [[ "${LW_ALLOW_UNVALIDATED:-false}" == true ]]; then
      warn "Profile ${profile:-?} is '$(P PROFILE_STATUS)', not validated on this hardware (allowed by LW_ALLOW_UNVALIDATED=true; record AC-3.1)"
    else
      bad "Profile ${profile:-?} is '$(P PROFILE_STATUS)', not validated (AC-3.1, PLAN P5). For the validation run itself: LW_ALLOW_UNVALIDATED=true"
    fi
    ;;
esac

# ---- GPUs ---------------------------------------------------------------------
if ! skipped gpu; then
  want="$(P VLLM_GPU_COUNT)"
  gpus="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | grep -c . || true)"
  if [[ "${gpus}" -eq "${want:-1}" ]]; then
    pass "${gpus} GPU(s) visible, profile needs ${want}"
  elif [[ "${gpus}" -gt "${want:-1}" ]]; then
    warn "${gpus} GPU(s) visible but profile ${profile:-?} uses ${want}: the rest stay idle"
  else
    bad "Host sees ${gpus:-0} GPU(s), profile ${profile:-?} needs ${want} (VLLM_GPU_COUNT; run scripts/verify/vm-check.sh)"
  fi
fi

[[ "${errors}" -eq 0 ]] || die "Preflight failed with ${errors} error(s)"
pass "Release preflight passed (${LW_WARNINGS} warning(s))"
