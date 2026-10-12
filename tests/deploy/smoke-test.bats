#!/usr/bin/env bats
# scripts/deploy/smoke-test.sh: the release gate. Includes the security
# acceptance criterion (unauthenticated requests MUST get 401).

load ../helpers/common
load ../helpers/stack

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/deploy/smoke-test.sh"

setup() {
  setup_sandbox
  load_stack_fixture
}

@test "passes against a healthy stack" {
  run bash "${SCRIPT}"
  assert_status 0
}

@test "fails if the gateway accepts an unauthenticated request" {
  echo 200 >"${SANDBOX}/curl.unauth"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "401"
}

@test "fails if the gateway accepts an invalid key" {
  echo 200 >"${SANDBOX}/curl.badkey"
  run bash "${SCRIPT}"
  assert_failure
}

@test "fails if the served model is not listed" {
  export SERVED_MODEL=some-other-model
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "lifewatch-chat"
}

@test "fails if end-to-end inference fails; --skip-inference skips only that check" {
  echo 500 >"${SANDBOX}/curl.inference"
  run bash "${SCRIPT}"
  assert_failure
  run bash "${SCRIPT}" --skip-inference
  assert_status 0
}

@test "fails if Open WebUI is unhealthy" {
  echo 503 >"${SANDBOX}/curl.webui"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "Open WebUI"
}

@test "fails if the ingress serves plain HTTP instead of redirecting to HTTPS" {
  echo 200 >"${SANDBOX}/curl.redirect"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "redirect"
}

@test "fails if the public API port accepts unauthenticated requests" {
  echo 200 >"${SANDBOX}/curl.ingress_unauth"
  run bash "${SCRIPT}"
  assert_failure
}

@test "fails if gateway admin endpoints are reachable through the ingress" {
  echo 200 >"${SANDBOX}/curl.ingress_admin"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "admin"
}

@test "verifies TLS against the lab CA with the public hostname" {
  run bash "${SCRIPT}"
  assert_status 0
  called curl "--cacert ${TLS_DIR}/live/ca.pem"
  called curl "--resolve ai.lifewatch.test:443:127.0.0.1"
}

@test "fails when vLLM rejects tool_choice=auto (agents could not use tools, R3-02)" {
  touch "${SANDBOX}/no-tools"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "VLLM_TOOL_CALL_PARSER"
}

@test "passes the tool-calling check when the backend returns a well-formed call" {
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "1 well-formed call(s)"
}

