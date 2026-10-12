#!/usr/bin/env bats
# Policy-as-code for the rendered Compose model. These encode ADR-006/007 and
# the production-readiness audit so a regression fails CI, not production.

load ../helpers/common

setup_file() {
  export RENDERED="${BATS_FILE_TMPDIR}/compose.json"
  docker compose --project-directory "${REPO_ROOT}" -f "${REPO_ROOT}/compose.yaml" \
    --env-file "${REPO_ROOT}/profiles/l40s-2.env" --env-file "${REPO_ROOT}/.env.example" \
    config --format json >"${RENDERED}"
}

q() { jq -r "$@" "${RENDERED}"; }

@test "compose renders with release.env + .env.example" {
  [[ -s "${RENDERED}" ]]
  [[ "$(q .name)" == lifewatch ]]
}

@test "compose fails fast when a required secret is missing" {
  # Drop only the master key: Compose versions differ in which missing
  # variable they report first, so leave exactly one missing.
  grep -v '^LITELLM_MASTER_KEY=' "${REPO_ROOT}/.env.example" >"${BATS_TEST_TMPDIR}/partial.env"
  run docker compose --project-directory "${REPO_ROOT}" -f "${REPO_ROOT}/compose.yaml" \
    --env-file "${REPO_ROOT}/profiles/l40s-2.env" --env-file "${BATS_TEST_TMPDIR}/partial.env" config -q
  assert_failure
  assert_output_contains "LITELLM_MASTER_KEY"
}

@test "every image is pinned by digest and none uses :latest" {
  run q '.services[] | .image | select((test("@sha256:[0-9a-f]{64}$") | not) or test(":latest"))'
  assert_status 0
  [[ -z "${output}" ]] || { echo "unpinned: ${output}"; false; }
}

@test "only the TLS ingress publishes on non-loopback addresses, and only 80/443/8443" {
  run q '.services | to_entries[] | select(.key != "ingress") | .value.ports[]? | select(.host_ip != "127.0.0.1") | .published'
  [[ -z "${output}" ]] || { echo "exposed: ${output}"; false; }
  [[ "$(q '[.services.ingress.ports[].target] | sort | join(",")')" == 80,443,8443 ]]
}

@test "the ingress serves TLS from TLS_DIR and the ACME webroot read-only" {
  [[ "$(q '.services.ingress.volumes[] | select(.target == "/etc/nginx/tls") | .read_only')" == true ]]
  [[ "$(q '.services.ingress.volumes[] | select(.target == "/var/www/acme") | .read_only')" == true ]]
  [[ "$(q '.services.ingress.cap_drop | join(",")')" == ALL ]]
}

@test "nginx template: modern TLS only, API exposes /v1 only, ACME challenge on port 80" {
  local t="${REPO_ROOT}/configs/ingress/templates/lifewatch.conf.template"
  grep -q 'ssl_protocols TLSv1.2 TLSv1.3;' "${t}"
  refute grep -Eq 'TLSv1(\.[01])?[ ;]' <(grep ssl_protocols "${t}" | sed 's/TLSv1.2//; s/TLSv1.3//')
  grep -q 'location /.well-known/acme-challenge/' "${t}"
  grep -q 'listen 8443 ssl' "${t}"
  grep -q 'location /v1/' "${t}"
  grep -q 'server_tokens off' "${t}"
}

@test "certbot is a tools-profile service: pinned, never started by a deploy" {
  run docker compose --project-directory "${REPO_ROOT}" -f "${REPO_ROOT}/compose.yaml" \
    --env-file "${REPO_ROOT}/profiles/l40s-2.env" --env-file "${REPO_ROOT}/.env.example" --profile tools config --format json
  assert_status 0
  [[ "$(jq -r '.services.certbot.image' <<<"${output}")" =~ ^certbot/certbot:v[0-9.]+@sha256:[0-9a-f]{64}$ ]]
  [[ "$(q '.services | has("certbot")')" == false ]]
}

@test "the inference backend is only reachable on the internal network" {
  [[ "$(q '.networks["backend-net"].internal')" == true ]]
  [[ "$(q '.services["vllm-backend"].networks | keys | join(",")')" == backend-net ]]
  [[ "$(q '.services["vllm-backend"].ports // [] | length')" == 0 ]]
  [[ "$(q '.services.postgres.networks | keys | join(",")')" == backend-net ]]
}

@test "no service uses host namespaces or privileged mode" {
  run q '.services | to_entries[] | select(.value.privileged == true or .value.ipc == "host" or .value.network_mode == "host" or .value.pid == "host") | .key'
  [[ -z "${output}" ]] || { echo "offenders: ${output}"; false; }
}

@test "every service sets no-new-privileges" {
  run q '.services | to_entries[] | select((.value.security_opt // []) | index("no-new-privileges:true") | not) | .key'
  [[ -z "${output}" ]] || { echo "missing: ${output}"; false; }
}

@test "every service has a healthcheck, a restart policy and bounded logs" {
  run q '.services | to_entries[] | select(.value.healthcheck.test == null) | .key'
  [[ -z "${output}" ]] || { echo "no healthcheck: ${output}"; false; }
  run q '.services | to_entries[] | select(.value.restart != "unless-stopped") | .key'
  [[ -z "${output}" ]] || { echo "no restart: ${output}"; false; }
  run q '.services | to_entries[] | select(.value.logging.options["max-size"] == null) | .key'
  [[ -z "${output}" ]] || { echo "unbounded logs: ${output}"; false; }
}

@test "vLLM runs offline from a pinned model revision, without remote code or prompt logging" {
  local cmd
  cmd="$(q '.services["vllm-backend"].command | join(" ")')"
  [[ "${cmd}" == *"--revision "* ]]
  [[ "${cmd}" != *"--enable-log-requests"* ]] # prompts stay out of logs (default since vLLM 0.10)
  [[ "${cmd}" != *"--trust-remote-code"* ]]
  [[ "${cmd}" != *"--api-key"* ]] # secret must come from env, not argv
  [[ "$(q '.services["vllm-backend"].environment.HF_HUB_OFFLINE')" == 1 ]]
  [[ -n "$(q '.services["vllm-backend"].environment.VLLM_API_KEY // empty')" ]]
}

@test "the gateway starts independently of model load" {
  [[ "$(q '.services["litellm-gateway"].depends_on | has("vllm-backend")')" == false ]]
}

@test "Open WebUI uses its real OAuth variable names and does not hold the master key" {
  local env='.services["open-webui"].environment'
  [[ -n "$(q "${env}.OAUTH_CLIENT_ID // empty")" ]]
  [[ "$(q "${env}.OPENID_PROVIDER_URL")" == */.well-known/openid-configuration ]]
  [[ "$(q "${env}.ENABLE_SIGNUP")" == false ]] # default; only the lab env may enable it
  [[ "$(q "${env}.CORS_ALLOW_ORIGIN")" == "$(q "${env}.WEBUI_URL")" ]]
  [[ "$(q "${env}.OIDC_CLIENT_ID // empty")" == "" ]]
  [[ "$(q "${env}.OPENAI_API_KEY")" != "$(q '.services["litellm-gateway"].environment.LITELLM_MASTER_KEY')" ]]
}

@test "Open WebUI takes roles and groups from Keycloak, never creates groups itself" {
  local env='.services["open-webui"].environment'
  [[ "$(q "${env}.ENABLE_OAUTH_ROLE_MANAGEMENT")" == true ]]
  [[ -n "$(q "${env}.OAUTH_ALLOWED_ROLES // empty")" && -n "$(q "${env}.OAUTH_ADMIN_ROLES // empty")" ]]
  [[ "$(q "${env}.OAUTH_ALLOWED_ROLES")" != *"*"* ]] # a wildcard would admit every Keycloak user
  [[ "$(q "${env}.DEFAULT_USER_ROLE")" == pending ]]
  [[ "$(q "${env}.ENABLE_OAUTH_GROUP_MANAGEMENT")" == true ]]
  [[ "$(q "${env}.ENABLE_OAUTH_GROUP_CREATION")" == false ]]
}

@test "the gateway prices tokens, so key budgets can trip (R3-03)" {
  local k v
  for k in input_cost_per_token output_cost_per_token; do
    v="$(yq -r ".model_list[0].litellm_params.${k}" "${REPO_ROOT}/configs/proxy/config.yaml")"
    awk -v v="${v}" 'BEGIN { exit !(v + 0 > 0) }' || { echo "${k}=${v}"; false; }
  done
}

@test "LiteLLM serves exactly the model alias vLLM exposes, in every GPU profile" {
  local f served
  for f in "${REPO_ROOT}"/profiles/*.env; do
    f="${f#"${REPO_ROOT}"/}"
    served="$(grep '^SERVED_MODEL_NAME=' "${REPO_ROOT}/${f}" | cut -d= -f2)"
    run yq -r '.model_list[].litellm_params.model' "${REPO_ROOT}/configs/proxy/config.yaml"
    [[ "${output}" == "openai/${served}" ]] || { echo "${f}: ${served} vs ${output}"; false; }
    run yq -r '.model_list[].model_name' "${REPO_ROOT}/configs/proxy/config.yaml"
    [[ "${output}" == "${served}" ]]
  done
}

# render_profile NAME: rendered compose model (JSON) for profiles/NAME.env
render_profile() {
  docker compose --project-directory "${REPO_ROOT}" -f "${REPO_ROOT}/compose.yaml" \
    --env-file "${REPO_ROOT}/profiles/$1.env" --env-file "${REPO_ROOT}/.env.example" config --format json
}

@test "each GPU profile reserves as many GPUs as it shards across, and pins its model (ADR-012)" {
  local p n json
  for p in l40s-1:1 l40s-2:2 lab:1; do
    n=${p#*:} p=${p%%:*}
    json="$(render_profile "${p}")"
    [[ "$(jq -r '.services["vllm-backend"].deploy.resources.reservations.devices[0].count' <<<"${json}")" == "${n}" ]] || { echo "${p}: GPU count"; false; }
    [[ "$(jq -r '.services["vllm-backend"].command | join(" ")' <<<"${json}")" == *"--tensor-parallel-size=${n}"* ]] || { echo "${p}: TP"; false; }
    grep -Eq '^MODEL_REVISION=[0-9a-f]{40}$' "${REPO_ROOT}/profiles/${p}.env"
    grep -qx "PROFILE_NAME=${p}" "${REPO_ROOT}/profiles/${p}.env"
    grep -qx "PROFILE_GPUS=${n}" "${REPO_ROOT}/profiles/${p}.env"
    grep -Eqx 'PROFILE_STATUS=(candidate|validated|lab)' "${REPO_ROOT}/profiles/${p}.env"
  done
}

@test "every profile turns on tool calling with a parser vLLM knows (ADR-014)" {
  local p cmd
  for p in l40s-1 l40s-2 lab; do
    cmd="$(render_profile "${p}" | jq -r '.services["vllm-backend"].command | join(" ")')"
    [[ "${cmd}" == *"--enable-auto-tool-choice"* ]] || { echo "${p}: tool choice off"; false; }
    # Parser names registered in vLLM v0.31.0 (vllm/tool_parsers, vllm/reasoning).
    [[ "${cmd}" =~ --tool-call-parser=(hermes|qwen3_coder|qwen3_xml|llama3_json|openai|mistral)( |$) ]] || { echo "${p}: tool parser"; false; }
    [[ "${cmd}" =~ --reasoning-parser=(qwen3|deepseek_r1|openai_gptoss)( |$) ]] || { echo "${p}: reasoning parser"; false; }
  done
}

@test "a profile serves at least 64k context unless it is the lab (ADR-014 contract)" {
  local p len
  for p in l40s-1 l40s-2; do
    len="$(grep '^VLLM_MAX_MODEL_LEN=' "${REPO_ROOT}/profiles/${p}.env" | cut -d= -f2)"
    [[ "${len}" -ge 65536 ]] || { echo "${p}: ${len}"; false; }
  done
}

@test "LiteLLM config is GitOps-only and uses a routing strategy that needs no Redis" {
  [[ "$(q '.services["litellm-gateway"].environment.STORE_MODEL_IN_DB')" == False ]]
  [[ "$(yq -r '.router_settings.routing_strategy' "${REPO_ROOT}/configs/proxy/config.yaml")" == simple-shuffle ]]
  [[ "$(yq -r '.model_list[0].litellm_params.api_key' "${REPO_ROOT}/configs/proxy/config.yaml")" == os.environ/VLLM_API_KEY ]]
}

@test ".env.example contains placeholders, never realistic secrets" {
  run grep -E '^(LITELLM_MASTER_KEY|POSTGRES_PASSWORD|OIDC_CLIENT_SECRET|WEBUI_SECRET_KEY|VLLM_API_KEY|OPENWEBUI_API_KEY)=' "${REPO_ROOT}/.env.example"
  assert_status 0
  while IFS= read -r line; do
    value="${line#*=}"
    [[ -z "${value}" || "${value}" == *CHANGE_ME* ]] || { echo "not a placeholder: ${line%%=*}"; false; }
  done <<<"${output}"
}
