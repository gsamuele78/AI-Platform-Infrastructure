#!/usr/bin/env bats
# scripts/ops/backup.sh + restore.sh: consistent, verified, checksummed.

load ../helpers/common
load ../helpers/stack

BACKUP="${BATS_TEST_DIRNAME}/../../scripts/ops/backup.sh"
RESTORE="${BATS_TEST_DIRNAME}/../../scripts/ops/restore.sh"

setup() {
  setup_sandbox
  load_stack_fixture
  OUT="${SANDBOX}/bk"
}

@test "backup writes a verified DB dump, a volume archive and checksums" {
  run bash "${BACKUP}" --out "${OUT}"
  assert_status 0
  [[ -s "${OUT}/litellm.pgdump" ]]
  [[ -s "${OUT}/openwebui_data.tgz" ]]
  [[ -s "${OUT}/tls.tgz" ]]
  tar -tzf "${OUT}/tls.tgz" | grep -q 'ca/ca.key'
  [[ "$(tar -tzf "${OUT}/tls.tgz")" != *acme-webroot* ]]
  (cd "${OUT}" && sha256sum -c SHA256SUMS)
  called docker "exec .*pg_restore --list"
  [[ "$(stat -c %a "${OUT}")" == 700 ]]
}

@test "backup stops Open WebUI for a consistent SQLite copy and restarts it" {
  run bash "${BACKUP}" --out "${OUT}"
  assert_status 0
  called docker "stop cid-open-webui"
  called docker "start cid-open-webui"
  [[ -f "${SANDBOX}/run/open-webui" ]]
}

@test "backup restarts Open WebUI even when archiving fails" {
  echo 1 >"${SANDBOX}/fail.tar"
  run bash "${BACKUP}" --out "${OUT}"
  assert_failure
  [[ -f "${SANDBOX}/run/open-webui" ]]
}

@test "backup fails loudly when Postgres is not running" {
  rm "${SANDBOX}/run/postgres"
  run bash "${BACKUP}" --out "${OUT}"
  assert_failure
  assert_output_contains "postgres"
}

@test "backup fails when pg_dump fails (no silent empty dump)" {
  echo 1 >"${SANDBOX}/fail.pg_dump"
  run bash "${BACKUP}" --out "${OUT}"
  assert_failure
}

@test "restore refuses a backup whose checksums do not match" {
  bash "${BACKUP}" --out "${OUT}"
  echo tampered >>"${OUT}/litellm.pgdump"
  run bash "${RESTORE}" --from "${OUT}" --yes
  assert_failure
  refute called docker "exec .*dropdb"
}

@test "restore asks for confirmation and aborts on anything but 'yes'" {
  bash "${BACKUP}" --out "${OUT}"
  run bash -c "echo no | bash '${RESTORE}' --from '${OUT}'"
  assert_failure
  refute called docker "exec .*dropdb"
}

@test "restore stops writers, recreates the DB, restores data in that order" {
  bash "${BACKUP}" --out "${OUT}"
  : >"${STUB_LOG}"
  run bash "${RESTORE}" --from "${OUT}" --yes
  assert_status 0
  called docker "stop cid-litellm-gateway"
  called docker "stop cid-open-webui"
  called docker "exec .*dropdb"
  called docker "exec -i .*pg_restore"
  called docker "run .*openwebui_data"
  local stop_line drop_line
  stop_line="$(grep -n 'stop cid-litellm-gateway' "${STUB_LOG}" | cut -d: -f1)"
  drop_line="$(grep -n 'dropdb' "${STUB_LOG}" | cut -d: -f1)"
  [[ "${stop_line}" -lt "${drop_line}" ]]
}

@test "default backup location is BACKUP_DIR from .env (the mounted backup volume)" {
  run bash "${BACKUP}"
  assert_status 0
  [[ -n "$(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -name SHA256SUMS)" ]]
}

@test "retention keeps only the newest N complete backups" {
  for i in 1 2 3; do bash "${BACKUP}" --keep 2 >/dev/null 2>&1; sleep 1; done
  [[ "$(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -name SHA256SUMS | wc -l)" -eq 2 ]]
}
