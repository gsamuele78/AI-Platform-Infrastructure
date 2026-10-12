#!/usr/bin/env bats
# scripts/deploy/deploy.sh + rollback.sh: immutable release snapshots,
# backup-before-change, health-gated cut-over, automatic rollback.

load ../helpers/common
load ../helpers/stack

DEPLOY="${BATS_TEST_DIRNAME}/../../scripts/deploy/deploy.sh"
ROLLBACK="${BATS_TEST_DIRNAME}/../../scripts/deploy/rollback.sh"

setup() {
  setup_sandbox
  load_stack_fixture
}

first_deploy() {
  run bash "${DEPLOY}"
  assert_status 0
  FIRST="$(current_release)"
  sleep 1 # release ids are second-resolution timestamps
  : >"${STUB_LOG}"
}

# Make the currently deployed release look like it ran a different LiteLLM
# image, so moving between it and a new release implies a DB schema change.
mutate_current_gateway_image() {
  local f="${LW_STATE_DIR}/releases/current/compose.yaml"
  sed -i -E 's|(litellm-database:)[^@]+@sha256:[0-9a-f]{64}|\1v0.0.1@sha256:1111111111111111111111111111111111111111111111111111111111111111|' "${f}"
  grep -q 'litellm-database:v0.0.1@' "${f}" # fail loudly if the image line moved
}

@test "refuses to deploy a dirty working tree" {
  echo " M compose.yaml" >"${SANDBOX}/git.status"
  run bash "${DEPLOY}"
  assert_failure
  assert_output_contains "uncommitted"
  not_called docker
}

@test "first deploy snapshots the release, waits for health, smoke-tests and cuts over" {
  run bash "${DEPLOY}"
  assert_status 0
  local rel
  rel="$(release_dirs | head -1)"
  [[ -f "${rel}/compose.yaml" && -f "${rel}/release.env" && -f "${rel}/configs/proxy/config.yaml" ]]
  [[ "$(basename "${rel}")" == *-abc1234 ]]
  called docker "compose .* pull"
  called docker "compose .* up -d --wait"
  [[ "$(current_release)" == "$(basename "${rel}")" ]]
  ! called docker "exec .*pg_dump" # nothing to back up yet
}

@test "subsequent deploy backs up data before touching anything" {
  first_deploy
  run bash "${DEPLOY}"
  assert_status 0
  local dump_line pull_line
  dump_line="$(grep -n 'pg_dump' "${STUB_LOG}" | head -1 | cut -d: -f1)"
  pull_line="$(grep -n 'compose .* pull' "${STUB_LOG}" | head -1 | cut -d: -f1)"
  [[ -n "${dump_line}" && "${dump_line}" -lt "${pull_line}" ]]
  [[ "$(cat "${LW_STATE_DIR}/releases/current/previous")" == "${FIRST}" ]]
}

@test "a transient pull failure is retried" {
  first_deploy
  echo 2 >"${SANDBOX}/fail.pull"
  run env LW_PULL_RETRY_DELAY=0 bash "${DEPLOY}"
  assert_status 0
  [[ "$(grep -c 'compose .* pull' "${STUB_LOG}")" -eq 3 ]]
}

@test "pull failure aborts with the old release untouched" {
  first_deploy
  echo 3 >"${SANDBOX}/fail.pull"
  export LW_PULL_RETRY_DELAY=0
  run bash "${DEPLOY}"
  assert_failure
  ! called docker "compose .* up"
  [[ "$(current_release)" == "${FIRST}" ]]
  [[ -n "$(find "${LW_STATE_DIR}/releases" -name FAILED)" ]]
}

@test "failed health wait triggers automatic rollback to the previous release" {
  first_deploy
  echo 1 >"${SANDBOX}/fail.up"
  run bash "${DEPLOY}"
  assert_failure
  assert_output_contains "rolled back"
  [[ "$(current_release)" == "${FIRST}" ]]
  called docker "compose .*releases/${FIRST} .* up -d --wait"
}

@test "failed smoke test triggers automatic rollback" {
  first_deploy
  echo 200 >"${SANDBOX}/curl.unauth"
  run bash "${DEPLOY}"
  assert_failure
  [[ "$(current_release)" == "${FIRST}" ]]
  called docker "compose .*releases/${FIRST} .* up -d --wait"
}

@test "--no-auto-rollback leaves the failed release for inspection" {
  first_deploy
  echo 1 >"${SANDBOX}/fail.up"
  run bash "${DEPLOY}" --no-auto-rollback
  assert_failure
  ! called docker "compose .*releases/${FIRST} .* up"
}

@test "auto-rollback does not restore data when stateful images are unchanged" {
  first_deploy
  echo 1 >"${SANDBOX}/fail.up"
  run bash "${DEPLOY}"
  assert_failure
  ! called docker "exec .*dropdb"
}

@test "auto-rollback restores the pre-deploy backup when a stateful image changed" {
  first_deploy
  mutate_current_gateway_image
  echo 1 >"${SANDBOX}/fail.up"
  run bash "${DEPLOY}"
  assert_failure
  called docker "exec .*dropdb"
  [[ "$(current_release)" == "${FIRST}" ]]
}

@test "manual rollback --previous returns to the prior release" {
  first_deploy
  run bash "${DEPLOY}"
  assert_status 0
  run bash "${ROLLBACK}" --previous --yes
  assert_status 0
  [[ "$(current_release)" == "${FIRST}" ]]
}

@test "manual rollback refuses to guess about data when stateful images differ" {
  first_deploy
  mutate_current_gateway_image
  run bash "${DEPLOY}"
  assert_status 0
  run bash "${ROLLBACK}" --previous --yes
  assert_failure
  assert_output_contains "--restore-backup"
  ! called docker "exec .*dropdb"
}

@test "manual rollback with --restore-backup restores data before starting old images" {
  first_deploy
  mutate_current_gateway_image
  run bash "${DEPLOY}"
  assert_status 0
  local bk
  bk="$(grep '^pre_deploy_backup=' "${LW_STATE_DIR}/releases/current/meta" | cut -d= -f2)"
  : >"${STUB_LOG}"
  run bash "${ROLLBACK}" --previous --restore-backup "${bk}" --yes
  assert_status 0
  local drop_line up_line
  drop_line="$(grep -n dropdb "${STUB_LOG}" | cut -d: -f1)"
  up_line="$(grep -n 'compose .* up' "${STUB_LOG}" | tail -1 | cut -d: -f1)"
  [[ "${drop_line}" -lt "${up_line}" ]]
  called docker "compose .* up -d --wait --wait-timeout 300 postgres"
}

@test "rollback to an unknown release fails" {
  run bash "${ROLLBACK}" --to does-not-exist --yes
  assert_failure
}
