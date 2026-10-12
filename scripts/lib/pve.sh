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
# Empty: any number of L40S on the host is fine, 1 or 2 are passed to the VM
# (ADR-012). Set it to require an exact count on the host.
: "${LW_EXPECTED_GPUS:=}"
: "${LW_QEMU_CONF_DIR:=/etc/pve/qemu-server}"
: "${LW_MODULES_LOAD_LINK:=/etc/modules-load.d/modules.conf}"
# The VM gets 1 or 2 GPUs: one profile per count (profiles/l40s-{1,2}.env).
LW_MAX_VM_GPUS=2

# shellcheck disable=SC2034 # consumed by the scripts that source this library
LW_VFIO_MODULES=(vfio vfio_iommu_type1 vfio_pci)
# shellcheck disable=SC2034
LW_MODPROBE_FILE="${LW_MODPROBE_DIR}/lifewatch-vfio.conf"
LW_GPUS=()
# Set by the caller from --gpu arguments; empty = every discovered GPU.
LW_REQUESTED_GPUS=()
# The GPUs this run passes through (subset of LW_GPUS), set by pve_select_gpus.
LW_SELECTED_GPUS=()

pve_discover_gpus() {
  mapfile -t LW_GPUS < <(lspci -D -n -d "${LW_GPU_PCI_ID}" | awk 'NF {print $1}')
}

# normalize_bdf 41:00 | 41:00.0 | 0000:41:00.0 -> 0000:41:00.0
normalize_bdf() {
  local a=$1
  [[ "${a}" =~ ^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}(\.[0-7])?$ ]] || return 1
  [[ "${a}" == ????:??:* ]] || a="0000:${a}"
  [[ "${a}" == *.? ]] || a="${a}.0"
  printf '%s\n' "${a,,}"
}

# pve_select_gpus: LW_SELECTED_GPUS = LW_REQUESTED_GPUS (validated) or all.
pve_select_gpus() {
  local r n g found rc=0
  LW_SELECTED_GPUS=()
  if [[ "${#LW_REQUESTED_GPUS[@]}" -eq 0 ]]; then
    LW_SELECTED_GPUS=("${LW_GPUS[@]}")
  else
    for r in "${LW_REQUESTED_GPUS[@]}"; do
      if ! n="$(normalize_bdf "${r}")"; then
        fail "--gpu '${r}' is not a PCI address (e.g. 0000:41:00.0)"
        rc=1
        continue
      fi
      found=0
      for g in "${LW_GPUS[@]}"; do [[ "${g}" == "${n}" ]] && found=1; done
      if [[ "${found}" -eq 1 ]]; then
        [[ " ${LW_SELECTED_GPUS[*]} " == *" ${n} "* ]] || LW_SELECTED_GPUS+=("${n}")
      else
        fail "--gpu ${n} is not an L40S (${LW_GPU_PCI_ID}) on this host; found: ${LW_GPUS[*]:-none}"
        rc=1
      fi
    done
  fi
  if [[ "${rc}" -eq 0 ]]; then
    if [[ "${#LW_SELECTED_GPUS[@]}" -lt 1 || "${#LW_SELECTED_GPUS[@]}" -gt "${LW_MAX_VM_GPUS}" ]]; then
      fail "${#LW_SELECTED_GPUS[@]} GPU(s) selected; the VM takes 1 or ${LW_MAX_VM_GPUS} (choose with --gpu <BDF>)"
      rc=1
    else
      pass "Selected for the VM: ${LW_SELECTED_GPUS[*]} (profile l40s-${#LW_SELECTED_GPUS[@]})"
    fi
  fi
  return "${rc}"
}

# pve_gpu_owner SLOT EXCEPT_VMID: VM ids (other than EXCEPT_VMID) whose config
# passes SLOT through, one per line. Passing one card to two VMs means the
# second VM fails to start, or steals the card if the first is stopped.
pve_gpu_owner() {
  local slot=$1 except=$2 f id
  for f in "${LW_QEMU_CONF_DIR}"/*.conf; do
    [[ -f "${f}" ]] || continue
    id="$(basename "${f}" .conf)"
    [[ "${id}" == "${except}" ]] && continue
    if grep -Eqi "^hostpci[0-9]+: (host=)?(0000:)?${slot#0000:}([.,;]|$)" "${f}"; then echo "${id}"; fi
  done
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

  if [[ -e "${LW_ETC_MODULES}" && ! -e "${LW_MODULES_LOAD_LINK}" ]]; then
    warn "${LW_MODULES_LOAD_LINK} is missing, so ${LW_ETC_MODULES} may not be read at boot; vfio modules then load only through the softdep rules"
  fi

  pve_discover_gpus
  if [[ "${#LW_GPUS[@]}" -eq 0 ]]; then
    fail "No GPU with ID ${LW_GPU_PCI_ID} found (lspci -nn | grep -i nvidia)"
    return 1
  elif [[ -n "${LW_EXPECTED_GPUS}" && "${#LW_GPUS[@]}" -ne "${LW_EXPECTED_GPUS}" ]]; then
    fail "Found ${#LW_GPUS[@]} GPU(s) with ID ${LW_GPU_PCI_ID}, expected ${LW_EXPECTED_GPUS}"
    rc=1
  else
    pass "Found ${#LW_GPUS[@]} GPU(s) with ID ${LW_GPU_PCI_ID}: ${LW_GPUS[*]}"
  fi

  pve_select_gpus || return 1
  for gpu in "${LW_SELECTED_GPUS[@]}"; do
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
  v="$(conf_get "${conf}" memory)"
  # vLLM reads the weights through the guest page cache, plus swap space and
  # the OS: below ~64 GiB a 30 GB model loads slowly or not at all.
  [[ "${v:-0}" -ge 65536 ]] || warn "VM memory is ${v:-default} MiB; give it at least 65536 (128 GiB recommended for the l40s-2 profile)"
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
