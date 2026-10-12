#!/usr/bin/env bash
# Undo exactly what one configure-passthrough.sh --apply run changed, using its
# manifest. Surgical, not wholesale: only the hostpci keys it added are deleted
# (unrelated VM edits since then survive), and host files are restored only if
# they still match what the apply wrote. Any drift aborts BEFORE mutating.
#   List:      rollback-passthrough.sh --list
#   Plan:      rollback-passthrough.sh --backup-dir <dir>
#   Execute:   rollback-passthrough.sh --backup-dir <dir> --apply
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/pve.sh
source "${LW_REPO_ROOT}/scripts/lib/pve.sh"

usage() {
  echo "Usage: $0 --list | --backup-dir <dir> [--apply]" >&2
  exit 2
}

BACKUP_DIR=""
APPLY=false
LIST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir)
      [[ $# -ge 2 ]] || usage
      BACKUP_DIR=$2
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --list)
      LIST=true
      shift
      ;;
    *) usage ;;
  esac
done
require_root

if [[ "${LIST}" == true ]]; then
  found=0
  for d in "${LW_PVE_BACKUP_ROOT}"/*/; do
    [[ -f "${d}manifest" ]] || continue
    found=1
    printf '%s  vm_id=%s created_at=%s%s\n' "${d%/}" \
      "$(manifest_get "${d}manifest" vm_id)" "$(manifest_get "${d}manifest" created_at)" \
      "$(manifest_get "${d}manifest" rolled_back_at >/dev/null && echo ' (rolled back)')"
  done
  [[ "${found}" -eq 1 ]] || info "No backups in ${LW_PVE_BACKUP_ROOT}"
  exit 0
fi

[[ -n "${BACKUP_DIR}" ]] || die "Specify the backup to restore with --backup-dir (see --list). There is no implicit 'latest': after repeated applies, the latest backup is not the original state."
MANIFEST="${BACKUP_DIR}/manifest"
[[ -f "${MANIFEST}" ]] || die "No manifest in ${BACKUP_DIR}; not a configure-passthrough.sh backup"
[[ "$(manifest_get "${MANIFEST}" format)" == 1 ]] || die "Unsupported manifest format in ${MANIFEST}"
if manifest_get "${MANIFEST}" rolled_back_at >/dev/null; then die "${BACKUP_DIR} was already rolled back"; fi

VM_ID="$(manifest_get "${MANIFEST}" vm_id)"
valid_vm_id "${VM_ID}" || die "Manifest has an invalid vm_id"
VM_CONF="$(qm config "${VM_ID}" 2>/dev/null)" || die "VM ${VM_ID} does not exist on this node"

# ---- Validate everything first ----------------------------------------------
errors=0
DELETE_KEYS=()
read -ra KEYS <<<"$(manifest_get "${MANIFEST}" hostpci_keys || true)"
for k in "${KEYS[@]}"; do
  expected="$(manifest_get "${MANIFEST}" "${k}")"
  current="$(conf_get "${VM_CONF}" "${k}")"
  if [[ -z "${current}" ]]; then
    info "${k} already absent from VM ${VM_ID}"
  elif [[ "${current}" == "${expected}" ]]; then
    DELETE_KEYS+=("${k}")
  else
    fail "${k} drifted since apply: expected '${expected}', found '${current}'. Resolve manually."
    errors=1
  fi
done

RESTORE_MODULES=0
if [[ "$(manifest_get "${MANIFEST}" modules_changed)" == 1 ]]; then
  if [[ "$(sha256_of "${LW_ETC_MODULES}")" == "$(manifest_get "${MANIFEST}" modules_sha256_after)" ]]; then
    RESTORE_MODULES=1
  else
    fail "${LW_ETC_MODULES} was modified after the apply; compare with ${BACKUP_DIR}/modules.orig and fix manually"
    errors=1
  fi
fi

MODPROBE_ACTION=none
if [[ "$(manifest_get "${MANIFEST}" modprobe_changed)" == 1 ]]; then
  if [[ ! -f "${LW_MODPROBE_FILE}" ]]; then
    info "${LW_MODPROBE_FILE} already absent"
  elif [[ "$(sha256_of "${LW_MODPROBE_FILE}")" != "$(manifest_get "${MANIFEST}" modprobe_sha256_after)" ]]; then
    fail "${LW_MODPROBE_FILE} was modified after the apply; fix manually"
    errors=1
  elif [[ "$(manifest_get "${MANIFEST}" modprobe_existed)" == 1 ]]; then
    MODPROBE_ACTION=restore
  else
    MODPROBE_ACTION=remove
  fi
fi

[[ "${errors}" -eq 0 ]] || die "Rollback aborted; nothing was changed"

info "Rollback plan for ${BACKUP_DIR}:"
[[ "${#DELETE_KEYS[@]}" -gt 0 ]] && info "  qm set ${VM_ID} --delete $(IFS=,; echo "${DELETE_KEYS[*]}")"
[[ "${RESTORE_MODULES}" -eq 1 ]] && info "  restore ${LW_ETC_MODULES}"
[[ "${MODPROBE_ACTION}" != none ]] && info "  ${MODPROBE_ACTION} ${LW_MODPROBE_FILE}"

if [[ "${APPLY}" != true ]]; then
  info "[DRY-RUN] No changes made. Re-run with --apply to execute."
  exit 0
fi
if pve_vm_running "${VM_ID}"; then die "VM ${VM_ID} is running; shut it down before rolling back"; fi

# ---- Execute ----------------------------------------------------------------
if [[ "${#DELETE_KEYS[@]}" -gt 0 ]]; then
  qm set "${VM_ID}" --delete "$(IFS=,; echo "${DELETE_KEYS[*]}")"
fi
HOST_CHANGED=0
if [[ "${RESTORE_MODULES}" -eq 1 ]]; then
  cp -p "${BACKUP_DIR}/modules.orig" "${LW_ETC_MODULES}.lifewatch.tmp"
  mv -f "${LW_ETC_MODULES}.lifewatch.tmp" "${LW_ETC_MODULES}"
  HOST_CHANGED=1
fi
case "${MODPROBE_ACTION}" in
  restore)
    cp -p "${BACKUP_DIR}/modprobe.orig" "${LW_MODPROBE_FILE}"
    HOST_CHANGED=1
    ;;
  remove)
    rm -f "${LW_MODPROBE_FILE}"
    HOST_CHANGED=1
    ;;
esac
[[ "${HOST_CHANGED}" -eq 1 ]] && update-initramfs -u -k all
echo "rolled_back_at=$(timestamp)" >>"${MANIFEST}"

pass "Rollback complete for VM ${VM_ID}"
[[ "${HOST_CHANGED}" -eq 1 ]] && warn "Reboot the HOST to release the GPUs from vfio-pci"
exit 0
