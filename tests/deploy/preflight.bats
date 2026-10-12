#!/usr/bin/env bats
# scripts/deploy/preflight.sh: refuse to deploy a misconfigured release.

load ../helpers/common
load ../helpers/stack

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/deploy/preflight.sh"

setup() {
  setup_sandbox
  load_stack_fixture
}

set_env() { sed -i "s|^$1=.*|$1=$2|" "${LW_ENV_FILE}"; }

@test "passes for a valid release" {
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "[PASS]"
}

@test "fails when the env file is readable by group or others" {
  chmod 644 "${LW_ENV_FILE}"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "600"
}

@test "fails when a CHANGE_ME placeholder remains" {
  set_env OIDC_CLIENT_SECRET CHANGE_ME
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "OIDC_CLIENT_SECRET"
}

@test "fails when a required secret is empty" {
  set_env WEBUI_SECRET_KEY ""
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "WEBUI_SECRET_KEY"
}

@test "fails when the master key lacks the sk- prefix" {
  set_env LITELLM_MASTER_KEY "0123456789abcdef0123456789abcdef"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "sk-"
}

@test "fails when Open WebUI is given the master key" {
  set_env OPENWEBUI_API_KEY "${STUB_MASTER_KEY}"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "OPENWEBUI_API_KEY"
}

@test "warns (does not fail) when the Open WebUI key is not issued yet" {
  set_env OPENWEBUI_API_KEY ""
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "[WARN]"
  assert_output_contains "issue-key.sh"
}

@test "fails when the Postgres password is not URL-safe" {
  set_env POSTGRES_PASSWORD 'p@ss/word:0123456789'
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "POSTGRES_PASSWORD"
}

@test "fails when the OIDC discovery URL is not a .well-known URL" {
  set_env OIDC_DISCOVERY_URL "https://auth.lifewatch.eu/realms/lifewatch"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "OIDC_DISCOVERY_URL"
}

@test "fails when the pinned model revision is not staged locally" {
  rm -rf "${MODEL_SNAPSHOT}"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "fetch-model.sh"
}

@test "fails when the guest sees fewer GPUs than the release needs (VLLM_GPU_COUNT)" {
  stub nvidia-smi 'echo "NVIDIA L40S"'
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "GPU"
}

@test "--skip gpu,model skips hardware-dependent checks" {
  rm -rf "${MODEL_SNAPSHOT}"
  stub nvidia-smi 'exit 1'
  run bash "${SCRIPT}" --skip gpu,model
  assert_status 0
}

@test "the GPU count comes from the release profile" {
  stub nvidia-smi 'echo "NVIDIA RTX A2000 Laptop GPU"'
  sed -i 's/^VLLM_GPU_COUNT=.*/VLLM_GPU_COUNT=1/' "${LW_RELEASE_ENV}"
  run bash "${SCRIPT}"
  assert_status 0
}

@test "fails when no TLS certificate is installed" {
  rm -f "${TLS_DIR}/live/fullchain.pem"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "tls-selfsigned.sh"
}

@test "fails when the certificate does not cover PUBLIC_HOSTNAME" {
  set_env PUBLIC_HOSTNAME other.lifewatch.test
  set_env WEBUI_URL https://other.lifewatch.test
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "other.lifewatch.test"
}

@test "fails when the private key does not match the certificate" {
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${TLS_DIR}/live/privkey.pem" 2>/dev/null
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "does not match"
}

@test "fails when the certificate is expired" {
  run bash "${REPO_ROOT}/scripts/ops/tls-selfsigned.sh" --force --days 1
  assert_status 0
  stub openssl 'if [[ " $* " == *" -checkend "* ]]; then exit 1; fi; exec /usr/bin/openssl "$@"'
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "expire"
}

@test "warns when WEBUI_URL is not on PUBLIC_HOSTNAME (OIDC redirect would break)" {
  set_env WEBUI_URL https://elsewhere.example
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "WEBUI_URL"
}

@test "fails when BACKUP_DIR does not exist" {
  rm -rf "${BACKUP_DIR}"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "BACKUP_DIR"
}

@test "warns when BACKUP_DIR is not a dedicated mount, fails if BACKUP_REQUIRE_MOUNT=true" {
  stub mountpoint 'exit 1'
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "mount"
  echo "BACKUP_REQUIRE_MOUNT=true" >>"${LW_ENV_FILE}"
  run bash "${SCRIPT}"
  assert_failure
}
