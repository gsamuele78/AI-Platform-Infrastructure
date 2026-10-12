#!/usr/bin/env bash
# Proxmox VE host + VM inspection helpers (read-only). Source after common.sh.
# Every path is overridable so the logic can be tested against a fake host.

[[ -n "${_LW_PVE_SH:-}" ]] && return 0
_LW_PVE_SH=1

: "${LW_SYSFS_ROOT:=/sys}"
: "${LW_ETC_MODULES:=/etc/modules}"
: "${LW_MODPROBE_DIR:=/etc/modprobe.d}"
: "${LW_PVE_BACKUP_ROOT:=/var/backups/lifewatch-pve}"
# NVIDIA L40S vendor:device. Matching on the ID, not the marketing name, keeps
# detection independent of how current the host's pci.ids database is.
: "${LW_GPU_PCI_ID:=10de:26b9}"
: "${LW_EXPECTED_GPUS:=2}"

# shellcheck disable=SC2034 # consumed by the scripts that source this library
LW_VFIO_MODULES=(vfio vfio_iommu_type1 vfio_pci)
# shellcheck disable=SC2034
LW_MODPROBE_FILE="${LW_MODPROBE_DIR}/lifewatch-vfio.conf"
LW_GPUS=()

pve_discover_gpus() {
  mapfile -t LW_GPUS < <(lspci -D -n -d "${LW_GPU_PCI_ID}" | awk 'NF {print $1}')
}

# pci_slot 0000:41:00.0 -> 0000:41:00 (all functions of the device)
pci_slot() { printf '%s\n' "${1%.*}"; }

# Check that a GPU's IOMMU group contains nothing but its own functions and PCI
# bridges. Passing a shared group would hand unrelated host devices to the VM.
pve_check_group_isolation() {
  local gpu=$1 slot group_dir dev name class ok=0
  slot="$(pci_slot "${gpu}")"
  group_dir="${LW_SYSFS_ROOT}/bus/pci/devices/${gpu}/iommu_group"
  if [[ ! -d "${group_dir}/devices" ]]; then
    fail "${gpu}: no IOMMU group (is the IOMMU enabled in firmware and kernel?)"
    return 1
  fi
  for dev in "${group_dir}"/devices/*; do
    name="$(basename "${dev}")"
    [[ "$(pci_slot "${name}")" == "${slot}" ]] && continue
    class="$(cat "${LW_SYSFS_ROOT}/bus/pci/devices/${name}/class" 2>/dev/null || echo unknown)"
    [[ "${class}" == 0x0604* ]] && continue
    fail "${gpu}: IOMMU group $(basename "$(readlink -f "${group_dir}")") also contains ${name} (class ${class}); passthrough would expose it to the VM"
    ok=1
  done
  [[ "${ok}" -eq 0 ]] && pass "${gpu}: IOMMU group $(basename "$(readlink -f "${group_dir}")") is isolated"
  return "${ok}"
}

pve_check_host_driver() {
  local gpu=$1 drv_link="${LW_SYSFS_ROOT}/bus/pci/devices/$1/driver" drv
  [[ -e "${drv_link}" ]] || return 0
  drv="$(basename "$(readlink -f "${drv_link}")")"
  case "${drv}" in
    vfio-pci) pass "${gpu}: bound to vfio-pci" ;;
    *) warn "${gpu}: host driver '${drv}' is bound; configure-passthrough.sh will bind vfio-pci (reboot required)" ;;
  esac
}

# Hard host requirements. Returns non-zero if passthrough is unsafe.
pve_host_checks() {
  local rc=0 groups gpu
  if command -v pveversion >/dev/null 2>&1; then
    pass "Proxmox VE: $(pveversion)"
  else
    fail "pveversion not found: this must run on a Proxmox VE host"
    return 1
  fi

  groups="$(find "${LW_SYSFS_ROOT}/kernel/iommu_groups" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
  if [[ "${groups}" -gt 0 ]]; then
    pass "IOMMU active (${groups} groups)"
  else
    fail "IOMMU not active: ${LW_SYSFS_ROOT}/kernel/iommu_groups is empty. Enable VT-d/AMD-Vi in firmware (and intel_iommu=on on older kernels)"
    rc=1
  fi

  pve_discover_gpus
  if [[ "${#LW_GPUS[@]}" -eq "${LW_EXPECTED_GPUS}" ]]; then
    pass "Found ${#LW_GPUS[@]} GPU(s) with ID ${LW_GPU_PCI_ID}: ${LW_GPUS[*]}"
  else
    fail "Found ${#LW_GPUS[@]} GPU(s) with ID ${LW_GPU_PCI_ID}, expected ${LW_EXPECTED_GPUS}"
    rc=1
  fi

  for gpu in "${LW_GPUS[@]}"; do
    pve_check_group_isolation "${gpu}" || rc=1
    pve_check_host_driver "${gpu}"
  done
  return "${rc}"
}

valid_vm_id() { [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]]; }

# conf_get "CONF_TEXT" KEY -> value of "KEY: value"
conf_get() { awk -v k="$2:" '$1 == k { sub(/^[^:]+: /, ""); print; exit }' <<<"$1"; }

pve_vm_running() { [[ "$(qm status "$1" 2>/dev/null)" == "status: running" ]]; }

# Hard VM requirements (machine type) + soft warnings that will bite later.
pve_vm_checks() {
  local conf=$1 rc=0 v
  v="$(conf_get "${conf}" machine)"
  if [[ "${v}" == *q35* ]]; then
    pass "VM machine type: ${v}"
  else
    fail "VM machine type is '${v:-i440fx (default)}'; pcie=1 passthrough requires q35"
    rc=1
  fi
  v="$(conf_get "${conf}" bios)"
  [[ "${v}" == ovmf ]] || warn "VM bios is '${v:-seabios}'; OVMF (UEFI) is strongly recommended for the L40S 64-bit BARs"
  v="$(conf_get "${conf}" cpu)"
  [[ "${v}" == host* ]] || warn "VM cpu is '${v:-kvm64}'; use 'cpu: host' so the guest gets enough physical address bits for large BARs"
  v="$(conf_get "${conf}" balloon)"
  [[ "${v}" == 0 ]] || warn "VM balloon is '${v:-enabled}'; passthrough pins all guest RAM, set 'balloon: 0'"
  return "${rc}"
}

# Normalise a hostpci value to its PCI slot (domain:bus:dev), or empty if the
# entry is not a raw address (e.g. a resource mapping).
hostpci_slot() {
  local addr=${1%%,*}
  addr=${addr#host=}
  [[ "${addr}" =~ ^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}(\.[0-7])?$ ]] || return 0
  [[ "${addr}" == ????:??:* ]] || addr="0000:${addr}"
  printf '%s\n' "${addr%.*}"
}

render_modprobe_conf() {
  cat <<EOF
# Managed by LifeWatch scripts/pve/configure-passthrough.sh. Do not edit by hand;
# use scripts/rollback/rollback-passthrough.sh to remove.
options vfio-pci ids=${LW_GPU_PCI_ID}
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
EOF
}
