#!/usr/bin/env bats
# scripts/rollback/rollback-passthrough.sh: manifest-driven, explicit backup
# selection, validate everything before mutating, refuse on drift.

load ../helpers/common
load ../helpers/pve

CONFIGURE="${BATS_TEST_DIRNAME}/../../scripts/pve/configure-passthrough.sh"
SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/rollback/rollback-passthrough.sh"

setup() {
  setup_sandbox
  load_pve_fixture
  as_root
  two_isolated_gpus
  fake_vm 100 stopped
  cp "${LW_ETC_MODULES}" "${SANDBOX}/modules.pristine"
  cp "${QM_DIR}/100.conf" "${SANDBOX}/vm.pristine"
  run bash "${CONFIGURE}" --vm-id 100 --apply
  assert_status 0
  BACKUP="$(find "${LW_PVE_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d)"
  : >"${STUB_LOG}"
}

@test "refuses to run as non-root" {
  as_user
  run bash "${SCRIPT}" --backup-dir "${BACKUP}"
  assert_failure
  assert_output_contains "root"
}

@test "requires an explicit backup (no implicit 'latest')" {
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "--backup-dir"
}

@test "--list shows available backups" {
  run bash "${SCRIPT}" --list
  assert_status 0
  assert_output_contains "$(basename "${BACKUP}")"
  assert_output_contains "vm_id=100"
}

@test "rejects a directory without a manifest" {
  mkdir -p "${SANDBOX}/bogus"
  run bash "${SCRIPT}" --backup-dir "${SANDBOX}/bogus"
  assert_failure
  assert_output_contains "manifest"
}

@test "dry-run without --apply changes nothing" {
  cp "${QM_DIR}/100.conf" "${SANDBOX}/vm.applied"
  run bash "${SCRIPT}" --backup-dir "${BACKUP}"
  assert_status 0
  assert_output_contains "DRY-RUN"
  refute called qm "set"
  cmp "${QM_DIR}/100.conf" "${SANDBOX}/vm.applied"
}

@test "apply restores the host and VM to the exact pre-change state" {
  run bash "${SCRIPT}" --backup-dir "${BACKUP}" --apply
  assert_status 0
  cmp "${LW_ETC_MODULES}" "${SANDBOX}/modules.pristine"
  [[ ! -e "${LW_MODPROBE_DIR}/lifewatch-vfio.conf" ]]
  cmp "${QM_DIR}/100.conf" "${SANDBOX}/vm.pristine"
  called qm "set 100 --delete hostpci0,hostpci1"
  called update-initramfs "-u -k all"
}

@test "only removes the hostpci entries it added; unrelated VM edits survive" {
  echo "net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0" >>"${QM_DIR}/100.conf"
  run bash "${SCRIPT}" --backup-dir "${BACKUP}" --apply
  assert_status 0
  grep -q '^net0: virtio=AA:BB:CC:DD:EE:FF' "${QM_DIR}/100.conf"
  refute grep -q '^hostpci' "${QM_DIR}/100.conf"
}

@test "refuses (and changes nothing) when a managed hostpci entry drifted" {
  sed -i 's/^hostpci1: .*/hostpci1: 0000:99:00,pcie=1/' "${QM_DIR}/100.conf"
  cp "${LW_ETC_MODULES}" "${SANDBOX}/modules.applied"
  run bash "${SCRIPT}" --backup-dir "${BACKUP}" --apply
  assert_failure
  assert_output_contains "hostpci1"
  refute called qm "set"
  cmp "${LW_ETC_MODULES}" "${SANDBOX}/modules.applied"
}

@test "refuses when /etc/modules was edited after the change" {
  echo "i2c-dev" >>"${LW_ETC_MODULES}"
  run bash "${SCRIPT}" --backup-dir "${BACKUP}" --apply
  assert_failure
  assert_output_contains "modules"
  refute called qm "set"
}

@test "refuses while the VM is running" {
  echo running >"${QM_DIR}/100.status"
  run bash "${SCRIPT}" --backup-dir "${BACKUP}" --apply
  assert_failure
  assert_output_contains "running"
}
