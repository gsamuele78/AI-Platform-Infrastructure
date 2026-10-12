#!/usr/bin/env bash
# shellcheck shell=bash
# GPU profile selection on the guest VM (ADR-012). Source after common.sh.
# A profile is a committed file profiles/<name>.env (model, capacity, parsers).
# Detection only *selects* among the profiles below; unknown hardware fails.

[[ -n "${_LW_PROFILE_SH:-}" ]] && return 0
_LW_PROFILE_SH=1

: "${LW_PROFILES_DIR:=${LW_REPO_ROOT}/profiles}"
# NVIDIA L40S vendor:device, same ID as the host side (scripts/lib/pve.sh).
: "${LW_GPU_PCI_ID:=10de:26b9}"

# Count GPUs on the PCI bus, not through nvidia-smi: the bus shows the
# passed-through cards even before the driver is installed or loaded.
l40s_count() {
  command -v lspci >/dev/null 2>&1 || {
    echo "lspci not found (apt-get install pciutils)" >&2
    return 1
  }
  lspci -n -d "${LW_GPU_PCI_ID}" | grep -c . || true
}

# detect_profile: print the profile name for this machine's hardware.
detect_profile() {
  local n
  n="$(l40s_count)" || return 1
  case "${n}" in
    1) echo l40s-1 ;;
    2) echo l40s-2 ;;
    *)
      echo "No profile for ${n} GPU(s) with PCI ID ${LW_GPU_PCI_ID}: supported are 1 or 2 L40S (ADR-012). Set LW_PROFILE to override." >&2
      return 1
      ;;
  esac
}

# release_env_file: the profile file a release is built from.
# Precedence: LW_RELEASE_ENV (explicit file, used by lab and tests) >
# LW_PROFILE (named profile) > hardware detection.
release_env_file() {
  local name f
  if [[ -n "${LW_RELEASE_ENV:-}" ]]; then
    printf '%s\n' "${LW_RELEASE_ENV}"
    return 0
  fi
  name="${LW_PROFILE:-}"
  [[ -n "${name}" ]] || name="$(detect_profile)" || return 1
  f="${LW_PROFILES_DIR}/${name}.env"
  [[ -f "${f}" ]] || {
    echo "Profile '${name}' not found (${f})" >&2
    return 1
  }
  printf '%s\n' "${f}"
}
