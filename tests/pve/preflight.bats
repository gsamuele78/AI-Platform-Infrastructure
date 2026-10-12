#!/usr/bin/env bats
# scripts/pve/preflight.sh: read-only host audit. Must FAIL (non-zero) on any
# condition that would make passthrough unsafe, and never mutate the host.

load ../helpers/common
load ../helpers/pve

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/pve/preflight.sh"

setup() {
  setup_sandbox
  load_pve_fixture
}

@test "fails when not running on a Proxmox VE host" {
  rm "${STUB_BIN}/pveversion"
  two_isolated_gpus
  run env PATH="${STUB_BIN}:/usr/bin:/bin" bash "${SCRIPT}"
  assert_failure
  assert_output_contains "Proxmox VE"
}

@test "fails when the IOMMU is not active (no iommu groups)" {
  echo "0000:41:00.0 0302: 10de:26b9 (rev a1)" >"${SANDBOX}/lspci.out"
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "IOMMU"
}

@test "fails when the GPU count differs from the expected count" {
  fake_gpu 0000:41:00.0 30
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "expected 2"
}

@test "honours LW_EXPECTED_GPUS" {
  fake_gpu 0000:41:00.0 30
  run env LW_EXPECTED_GPUS=1 bash "${SCRIPT}"
  assert_status 0
}

@test "fails when a GPU shares its IOMMU group with an unrelated device" {
  two_isolated_gpus
  fake_pci 0000:42:00.0 0x020000 30 # NIC in the same group as GPU 0
  run bash "${SCRIPT}"
  assert_failure
  assert_output_contains "0000:42:00.0"
}

@test "accepts PCI bridges and sibling functions in the GPU group" {
  two_isolated_gpus
  fake_pci 0000:40:01.1 0x060400 30 # root port bridge
  fake_pci 0000:41:00.1 0x040300 30 # audio function on the same slot
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "[PASS]"
}

@test "warns when the host has a GPU driver bound" {
  fake_gpu 0000:41:00.0 30 nvidia
  fake_gpu 0000:c1:00.0 70
  run bash "${SCRIPT}"
  assert_status 0
  assert_output_contains "[WARN]"
  assert_output_contains "nvidia"
}

@test "makes no changes to the host" {
  two_isolated_gpus
  cp "${LW_ETC_MODULES}" "${SANDBOX}/modules.before"
  run bash "${SCRIPT}"
  assert_status 0
  not_called qm
  not_called update-initramfs
  cmp "${LW_ETC_MODULES}" "${SANDBOX}/modules.before"
}
