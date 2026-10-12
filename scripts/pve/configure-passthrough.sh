#!/usr/bin/env bash
# Attach both L40S GPUs to a VM via vfio-pci passthrough.
#   Plan (default):  configure-passthrough.sh --vm-id 100
#   Apply:           configure-passthrough.sh --vm-id 100 --apply
# Apply backs up every touched file, writes a manifest consumed by
# scripts/rollback/rollback-passthrough.sh, and is idempotent.
# The kernel command line is intentionally NOT modified (bootloader-specific);
# preflight fails if the IOMMU is not active.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/pve.sh
source "${LW_REPO_ROOT}/scripts/lib/pve.sh"

usage() {
  echo "Usage: $0 --vm-id <VMID> [--apply]" >&2
  exit 2
}

VM_ID=""
APPLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-id)
      [[ $# -ge 2 ]] || usage
      VM_ID=$2
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    -h | --help) usage ;;
    *)
      log FAIL "Unknown argument: $1"
      usage
      ;;
  esac
done
[[ -n "${VM_ID}" ]] || usage
valid_vm_id "${VM_ID}" || die "Invalid VM id '${VM_ID}' (expected 100-999999999)"
require_root

pve_host_checks || die "Host preflight failed; nothing was changed"

VM_CONF="$(qm config "${VM_ID}" 2>/dev/null)" || die "VM ${VM_ID} does not exist on this node"
pve_vm_checks "${VM_CONF}" || die "VM ${VM_ID} is not suitable for PCIe passthrough; nothing was changed"

# ---- Plan -------------------------------------------------------------------
declare -A used_index=() attached_slot=()
for i in $(seq 0 15); do
  v="$(conf_get "${VM_CONF}" "hostpci${i}")"
  [[ -n "${v}" ]] || continue
  used_index[${i}]=1
  s="$(hostpci_slot "${v}")"
  [[ -n "${s}" ]] && attached_slot[${s}]=1
done

PLAN_KEYS=()
declare -A PLAN_VALUE=()
next=0
for gpu in "${LW_GPUS[@]}"; do
  slot="$(pci_slot "${gpu}")"
  [[ -n "${attached_slot[${slot}]:-}" ]] && continue
  while [[ -n "${used_index[${next}]:-}" ]]; do next=$((next + 1)); done
  [[ "${next}" -le 15 ]] || die "No free hostpci slot on VM ${VM_ID}"
  PLAN_KEYS+=("hostpci${next}")
  PLAN_VALUE["hostpci${next}"]="${slot},pcie=1"
  used_index[${next}]=1
done

MISSING_MODULES=()
for m in "${LW_VFIO_MODULES[@]}"; do
  grep -qx "${m}" "${LW_ETC_MODULES}" || MISSING_MODULES+=("${m}")
done

WANT_MODPROBE="$(render_modprobe_conf)"
MODPROBE_CHANGED=0
if [[ ! -f "${LW_MODPROBE_FILE}" ]] || [[ "$(cat "${LW_MODPROBE_FILE}")" != "${WANT_MODPROBE}" ]]; then
  MODPROBE_CHANGED=1
fi

if [[ "${#PLAN_KEYS[@]}" -eq 0 && "${#MISSING_MODULES[@]}" -eq 0 && "${MODPROBE_CHANGED}" -eq 0 ]]; then
  pass "VM ${VM_ID} and host are already configured for passthrough; nothing to do"
  exit 0
fi

info "Planned changes:"
for k in "${PLAN_KEYS[@]}"; do info "  qm set ${VM_ID}  ${k}: ${PLAN_VALUE[${k}]}"; done
if [[ "${#MISSING_MODULES[@]}" -gt 0 ]]; then info "  ${LW_ETC_MODULES}: append ${MISSING_MODULES[*]}"; fi
if [[ "${MODPROBE_CHANGED}" -eq 1 ]]; then info "  ${LW_MODPROBE_FILE}: bind ${LW_GPU_PCI_ID} to vfio-pci before nouveau/nvidia"; fi
if [[ "${#MISSING_MODULES[@]}" -gt 0 || "${MODPROBE_CHANGED}" -eq 1 ]]; then info "  update-initramfs -u -k all (host reboot required)"; fi

if [[ "${APPLY}" != true ]]; then
  info "[DRY-RUN] No changes made. Re-run with --apply to execute."
  exit 0
fi

if pve_vm_running "${VM_ID}"; then die "VM ${VM_ID} is running; shut it down before applying (qm shutdown ${VM_ID})"; fi

# ---- Backup + manifest (written before any mutation) ------------------------
BACKUP_DIR="${LW_PVE_BACKUP_ROOT}/$(timestamp)-vm${VM_ID}"
mkdir -p "${LW_PVE_BACKUP_ROOT}"
mkdir -m 0700 "${BACKUP_DIR}"
cp -p "${LW_ETC_MODULES}" "${BACKUP_DIR}/modules.orig"
printf '%s\n' "${VM_CONF}" >"${BACKUP_DIR}/vm-${VM_ID}.conf.orig"
MODPROBE_EXISTED=0
if [[ -f "${LW_MODPROBE_FILE}" ]]; then
  MODPROBE_EXISTED=1
  cp -p "${LW_MODPROBE_FILE}" "${BACKUP_DIR}/modprobe.orig"
fi

# Render new file contents up front so the manifest records their hashes and
# each file is replaced atomically (tmp + mv), never left half-written.
NEW_MODULES="${BACKUP_DIR}/modules.new"
cp -p "${LW_ETC_MODULES}" "${NEW_MODULES}"
for m in "${MISSING_MODULES[@]}"; do echo "${m}" >>"${NEW_MODULES}"; done
NEW_MODPROBE="${BACKUP_DIR}/modprobe.new"
printf '%s\n' "${WANT_MODPROBE}" >"${NEW_MODPROBE}"

{
  echo "format=1"
  echo "vm_id=${VM_ID}"
  echo "created_at=$(timestamp)"
  echo "hostpci_keys=${PLAN_KEYS[*]}"
  for k in "${PLAN_KEYS[@]}"; do echo "${k}=${PLAN_VALUE[${k}]}"; done
  echo "modules_changed=$([[ ${#MISSING_MODULES[@]} -gt 0 ]] && echo 1 || echo 0)"
  echo "modules_sha256_after=$(sha256_of "${NEW_MODULES}")"
  echo "modprobe_existed=${MODPROBE_EXISTED}"
  echo "modprobe_changed=${MODPROBE_CHANGED}"
  echo "modprobe_sha256_after=$(sha256_of "${NEW_MODPROBE}")"
} >"${BACKUP_DIR}/manifest"
info "Backup and manifest written to ${BACKUP_DIR}"
trap 'fail "Apply interrupted. Inspect, then roll back: scripts/rollback/rollback-passthrough.sh --backup-dir ${BACKUP_DIR} --apply"' ERR

# ---- Apply ------------------------------------------------------------------
HOST_CHANGED=0
if [[ "${#MISSING_MODULES[@]}" -gt 0 ]]; then
  cp -p "${NEW_MODULES}" "${LW_ETC_MODULES}.lifewatch.tmp"
  mv -f "${LW_ETC_MODULES}.lifewatch.tmp" "${LW_ETC_MODULES}"
  HOST_CHANGED=1
fi
if [[ "${MODPROBE_CHANGED}" -eq 1 ]]; then
  cp "${NEW_MODPROBE}" "${LW_MODPROBE_FILE}.lifewatch.tmp"
  mv -f "${LW_MODPROBE_FILE}.lifewatch.tmp" "${LW_MODPROBE_FILE}"
  HOST_CHANGED=1
fi
rm -f "${NEW_MODULES}" "${NEW_MODPROBE}"

if [[ "${#PLAN_KEYS[@]}" -gt 0 ]]; then
  QM_ARGS=()
  for k in "${PLAN_KEYS[@]}"; do QM_ARGS+=("--${k}" "${PLAN_VALUE[${k}]}"); done
  qm set "${VM_ID}" "${QM_ARGS[@]}"
fi

if [[ "${HOST_CHANGED}" -eq 1 ]]; then
  info "Regenerating initramfs (this can take a minute)"
  update-initramfs -u -k all
fi
trap - ERR

pass "Passthrough configured. Backup: ${BACKUP_DIR}"
if [[ "${HOST_CHANGED}" -eq 1 ]]; then
  warn "Reboot the HOST to bind vfio-pci, then re-run scripts/pve/preflight.sh before starting VM ${VM_ID}"
fi
info "Rollback: scripts/rollback/rollback-passthrough.sh --backup-dir ${BACKUP_DIR} --apply"
