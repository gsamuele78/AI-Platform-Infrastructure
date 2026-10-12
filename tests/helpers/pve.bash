# shellcheck shell=bash disable=SC2016
# Fake Proxmox host: sysfs PCI tree, IOMMU groups, lspci, qm, pveversion,
# update-initramfs, /etc/modules and /etc/modprobe.d, all under $SANDBOX.

load_pve_fixture() {
  export LW_SYSFS_ROOT="${SANDBOX}/sys"
  export LW_ETC_MODULES="${SANDBOX}/etc/modules"
  export LW_MODPROBE_DIR="${SANDBOX}/etc/modprobe.d"
  export LW_PVE_BACKUP_ROOT="${SANDBOX}/backups"
  export QM_DIR="${SANDBOX}/qm"
  # qm's config files double as /etc/pve/qemu-server/<vmid>.conf
  export LW_QEMU_CONF_DIR="${QM_DIR}"
  export LW_MODULES_LOAD_LINK="${SANDBOX}/etc/modules-load.d/modules.conf"
  mkdir -p "$(dirname "${LW_MODULES_LOAD_LINK}")"
  ln -sfn ../modules "${LW_MODULES_LOAD_LINK}"
  mkdir -p "${LW_SYSFS_ROOT}/bus/pci/devices" "${LW_SYSFS_ROOT}/kernel/iommu_groups" \
    "${LW_MODPROBE_DIR}" "${QM_DIR}" "$(dirname "${LW_ETC_MODULES}")"
  printf '# /etc/modules: kernel modules to load at boot time.\n' >"${LW_ETC_MODULES}"
  : >"${SANDBOX}/lspci.out"

  stub pveversion 'echo "pve-manager/9.2.1/abcdef (running kernel: 6.14.8-2-pve)"'
  stub update-initramfs ''
  stub_lspci
  # Minimal qm emulation backed by $QM_DIR/<vmid>.conf and $QM_DIR/<vmid>.status
  stub qm '
cmd=$1; vmid=$2; shift 2
conf="$QM_DIR/$vmid.conf"
case "$cmd" in
  config) [[ -f "$conf" ]] || { echo "Configuration file does not exist" >&2; exit 2; }; cat "$conf" ;;
  status) [[ -f "$conf" ]] || exit 2; echo "status: $(cat "$QM_DIR/$vmid.status" 2>/dev/null || echo stopped)" ;;
  set)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --delete) IFS=, read -ra keys <<<"$2"; for k in "${keys[@]}"; do sed -i "/^$k: /d" "$conf"; done; shift 2 ;;
        --*) k=${1#--}; sed -i "/^$k: /d" "$conf"; echo "$k: $2" >>"$conf"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  *) exit 1 ;;
esac'
}

# fake_pci ADDR CLASS GROUP [DRIVER]: register a PCI function in sysfs + IOMMU group.
fake_pci() {
  local addr=$1 class=$2 group=$3 driver=${4:-}
  local dev="${LW_SYSFS_ROOT}/bus/pci/devices/${addr}"
  local grp="${LW_SYSFS_ROOT}/kernel/iommu_groups/${group}"
  mkdir -p "${dev}" "${grp}/devices"
  echo "${class}" >"${dev}/class"
  ln -sfn "${grp}" "${dev}/iommu_group"
  ln -sfn "${dev}" "${grp}/devices/${addr}"
  if [[ -n "${driver}" ]]; then
    mkdir -p "${LW_SYSFS_ROOT}/bus/pci/drivers/${driver}"
    ln -sfn "${LW_SYSFS_ROOT}/bus/pci/drivers/${driver}" "${dev}/driver"
  fi
}

# fake_gpu ADDR GROUP: an L40S (10de:26b9) visible to lspci and sysfs.
fake_gpu() {
  fake_pci "$1" 0x030200 "$2" "${3:-}"
  echo "$1 0302: 10de:26b9 (rev a1)" >>"${SANDBOX}/lspci.out"
}

two_isolated_gpus() {
  fake_gpu 0000:41:00.0 30
  fake_gpu 0000:c1:00.0 70
}

# fake_vm VMID [STATUS] [EXTRA_CONF_LINES...]
fake_vm() {
  local vmid=$1 status=${2:-stopped}
  shift
  [[ $# -gt 0 ]] && shift
  {
    echo "bios: ovmf"
    echo "cpu: host"
    echo "machine: q35"
    echo "memory: 262144"
    echo "balloon: 0"
    echo "scsi0: local-lvm:vm-${vmid}-disk-0,size=200G"
    for line in "$@"; do echo "${line}"; done
  } >"${QM_DIR}/${vmid}.conf"
  echo "${status}" >"${QM_DIR}/${vmid}.status"
}
