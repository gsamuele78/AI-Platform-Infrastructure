#!/usr/bin/env bats
# scripts/pve/configure-passthrough.sh: plan by default, mutate only with
# --apply, back up first, record a manifest, and be idempotent.

load ../helpers/common
load ../helpers/pve

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/pve/configure-passthrough.sh"

setup() {
  setup_sandbox
  load_pve_fixture
  as_root
  two_isolated_gpus
  fake_vm 100 stopped
}

backup_dirs() { find "${LW_PVE_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; }

@test "refuses to run as non-root" {
  as_user
  run bash "${SCRIPT}" --vm-id 100
  assert_failure
  assert_output_contains "root"
}

@test "rejects a non-numeric VM id" {
  run bash "${SCRIPT}" --vm-id 'abc;rm'
  assert_failure
  assert_output_contains "VM id"
}

@test "rejects unknown arguments" {
  run bash "${SCRIPT}" --vm-id 100 --yolo
  assert_failure
}

@test "fails when the VM does not exist" {
  run bash "${SCRIPT}" --vm-id 999
  assert_failure
  assert_output_contains "999"
}

@test "default mode is a dry-run that changes nothing" {
  cp "${LW_ETC_MODULES}" "${SANDBOX}/modules.before"
  run bash "${SCRIPT}" --vm-id 100
  assert_status 0
  assert_output_contains "DRY-RUN"
  assert_output_contains "hostpci0: 0000:41:00,pcie=1"
  refute called qm "set"
  not_called update-initramfs
  cmp "${LW_ETC_MODULES}" "${SANDBOX}/modules.before"
  [[ -z "$(backup_dirs)" ]]
}

@test "aborts the apply when host preflight fails (GPU missing)" {
  : >"${SANDBOX}/lspci.out"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_failure
  refute called qm "set"
}

@test "refuses to apply while the VM is running" {
  echo running >"${QM_DIR}/100.status"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_failure
  assert_output_contains "running"
  refute called qm "set"
}

@test "refuses to apply when the VM machine type is not q35" {
  sed -i 's/^machine: q35/machine: pc-i440fx-9.0/' "${QM_DIR}/100.conf"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_failure
  assert_output_contains "q35"
}

@test "apply backs up, binds vfio, attaches both GPUs and writes a manifest" {
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_status 0

  local dir
  dir="$(backup_dirs)"
  [[ -n "${dir}" ]]
  [[ -f "${dir}/manifest" ]]
  [[ -f "${dir}/vm-100.conf.orig" ]]
  [[ -f "${dir}/modules.orig" ]]
  grep -q '^vm_id=100$' "${dir}/manifest"
  grep -q '^hostpci_keys=hostpci0 hostpci1$' "${dir}/manifest"

  grep -q '^hostpci0: 0000:41:00,pcie=1$' "${QM_DIR}/100.conf"
  grep -q '^hostpci1: 0000:c1:00,pcie=1$' "${QM_DIR}/100.conf"
  for m in vfio vfio_iommu_type1 vfio_pci; do grep -qx "${m}" "${LW_ETC_MODULES}"; done
  grep -q 'options vfio-pci ids=10de:26b9' "${LW_MODPROBE_DIR}/lifewatch-vfio.conf"
  grep -q 'softdep nouveau pre: vfio-pci' "${LW_MODPROBE_DIR}/lifewatch-vfio.conf"
  called update-initramfs "-u -k all"
}

@test "uses free hostpci slots and never overwrites existing passthrough entries" {
  fake_vm 100 stopped "hostpci0: 0000:05:00,pcie=1"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_status 0
  grep -q '^hostpci0: 0000:05:00,pcie=1$' "${QM_DIR}/100.conf"
  grep -q '^hostpci1: 0000:41:00,pcie=1$' "${QM_DIR}/100.conf"
  grep -q '^hostpci2: 0000:c1:00,pcie=1$' "${QM_DIR}/100.conf"
}

@test "does not duplicate modules that are already listed" {
  printf 'vfio\nvfio_pci\n' >>"${LW_ETC_MODULES}"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_status 0
  [[ "$(grep -cx vfio "${LW_ETC_MODULES}")" -eq 1 ]]
  [[ "$(grep -cx vfio_pci "${LW_ETC_MODULES}")" -eq 1 ]]
}

@test "second apply is a no-op: no new backup, no qm calls" {
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_status 0
  : >"${STUB_LOG}"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_status 0
  assert_output_contains "already configured"
  refute called qm "set"
  not_called update-initramfs
  [[ "$(backup_dirs | wc -l)" -eq 1 ]]
}

@test "warns about ballooning and non-host CPU types" {
  sed -i 's/^balloon: 0/balloon: 1024/; s/^cpu: host/cpu: x86-64-v2-AES/' "${QM_DIR}/100.conf"
  run bash "${SCRIPT}" --vm-id 100
  assert_status 0
  assert_output_contains "balloon"
  assert_output_contains "cpu"
}

@test "attaches the single GPU of a one-L40S host" {
  : >"${SANDBOX}/lspci.out"
  rm -rf "${LW_SYSFS_ROOT}/bus/pci/devices"/* "${LW_SYSFS_ROOT}/kernel/iommu_groups"/*
  fake_gpu 0000:41:00.0 30
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_status 0
  grep -q '^hostpci0: 0000:41:00,pcie=1$' "${QM_DIR}/100.conf"
  refute grep -q '^hostpci1:' "${QM_DIR}/100.conf"
}

@test "--gpu attaches only the selected card and leaves the other on the host" {
  run bash "${SCRIPT}" --vm-id 100 --gpu 0000:c1:00.0 --apply
  assert_status 0
  grep -q '^hostpci0: 0000:c1:00,pcie=1$' "${QM_DIR}/100.conf"
  refute grep -q '0000:41:00' "${QM_DIR}/100.conf"
  grep -q '^hostpci_keys=hostpci0$' "$(backup_dirs)/manifest"
}

@test "a second VM can take the other card with --gpu" {
  fake_vm 101 stopped
  run bash "${SCRIPT}" --vm-id 100 --gpu 0000:41:00.0 --apply
  assert_status 0
  run bash "${SCRIPT}" --vm-id 101 --gpu 0000:c1:00.0 --apply
  assert_status 0
  grep -q '^hostpci0: 0000:c1:00,pcie=1$' "${QM_DIR}/101.conf"
}

@test "refuses a card that another VM already passes through" {
  fake_vm 101 stopped "hostpci0: 0000:41:00,pcie=1"
  run bash "${SCRIPT}" --vm-id 100 --apply
  assert_failure
  assert_output_contains "already passed through to VM(s) 101"
  refute called qm "set"
  [[ -z "$(backup_dirs)" ]]
}

@test "the owner check also matches short and function-qualified addresses" {
  fake_vm 101 stopped "hostpci3: host=41:00.0,pcie=1,x-vga=0"
  run bash "${SCRIPT}" --vm-id 100 --gpu 0000:41:00.0
  assert_failure
  assert_output_contains "VM(s) 101"
}

@test "warns when the VM has too little memory for model loading" {
  sed -i 's/^memory: .*/memory: 32768/' "${QM_DIR}/100.conf"
  run bash "${SCRIPT}" --vm-id 100
  assert_status 0
  assert_output_contains "65536"
}

