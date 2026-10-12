#!/usr/bin/env bash
# Laptop lab prerequisites (Level 3, docs/operations/LAB.md), checked in phases.
#   tests/lab/setup.sh             check only: every phase, every problem, no changes
#   sudo tests/lab/setup.sh --apply   also fix what can be fixed safely, idempotently
# Fixable (with --apply, as root): NVIDIA Container Toolkit, the CDI spec for
# the current driver, LAB_DIR owned by the invoking user. Never touched: the
# driver, other files on the disk, your normal Podman storage.
# Exit 0 = ready for `make lab-gpu` (run it WITHOUT sudo); 1 = something left.
set -uo pipefail

: "${LAB_DIR:=/srv/lifewatch-lab}"
: "${LW_CDI_SPEC:=/etc/cdi/nvidia.yaml}"
: "${LW_SUBID_FILES:=/etc/subuid /etc/subgid}"
: "${LW_MIN_DRIVER:=580}"
: "${LW_MIN_VRAM_MIB:=4000}"
# First run: ~11.4 GB of compressed images (vLLM 9.0) unpack to roughly twice
# that, plus the model (1.75 GB) and pull scratch space. Estimate; adjust here.
: "${LW_LAB_FIRST_RUN_GB:=30}"
: "${LW_LAB_RERUN_GB:=3}"
: "${LW_LAB_PORTS:=8081 8444 8445 4000 8080}"
: "${LW_TOOLKIT_REPO_LIST:=/etc/apt/sources.list.d/nvidia-container-toolkit.list}"

APPLY=false
case "${1:-}" in
  --apply) APPLY=true ;;
  "" | --check) ;;
  -h | --help) sed -n '2,9p' "$0"; exit 0 ;;
  *) echo "Usage: $0 [--check | --apply]" >&2; exit 2 ;;
esac

if [[ -t 2 ]]; then G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' B=$'\e[1m' N=$'\e[0m'; else G="" R="" Y="" B="" N=""; fi
PHASES=8 phase=0 problems=0 fixed=0
TODO=()
phase() { phase=$((phase + 1)); printf '\n%s[%d/%d] %s%s\n' "${B}" "${phase}" "${PHASES}" "$*" "${N}" >&2; }
ok() { printf '  %s✔%s %s\n' "${G}" "${N}" "$*" >&2; }
note() { printf '  · %s\n' "$*" >&2; }
bad() { printf '  %s✘%s %s\n' "${R}" "${N}" "$1" >&2; problems=$((problems + 1)); [[ -n "${2:-}" ]] && TODO+=("$2"); }
fix() { printf '  %s→%s %s\n' "${Y}" "${N}" "$*" >&2; }
did() { printf '  %s✔%s %s (done now)\n' "${G}" "${N}" "$*" >&2; fixed=$((fixed + 1)); }

IS_ROOT=false
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=true
if [[ "${APPLY}" == true && "${IS_ROOT}" != true ]]; then
  echo "--apply changes the system: run it with sudo (sudo $0 --apply)" >&2
  exit 2
fi
# The lab runs rootless as the person who called sudo, never as root.
LAB_USER="${SUDO_USER:-$(id -un)}"
[[ "${LAB_USER}" == root ]] && { echo "Run as your normal user (with sudo for --apply), not from a root shell" >&2; exit 2; }
LAB_GROUP="$(id -gn "${LAB_USER}")"
# can_fix: true when this run may change the system.
can_fix() { [[ "${APPLY}" == true ]]; }

# ---- 1 ---------------------------------------------------------------------
phase "System"
. /etc/os-release 2>/dev/null && note "${PRETTY_NAME:-unknown OS}, kernel $(uname -r), user ${LAB_USER}"
for c in docker jq curl openssl awk ss; do
  pkg=${c}
  [[ "${c}" == ss ]] && pkg=iproute2
  [[ "${c}" == docker ]] && pkg=docker-ce-cli
  command -v "${c}" >/dev/null 2>&1 || bad "${c} not found" "apt-get install ${pkg}"
done
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    ok "docker CLI + compose plugin (client only; the lab talks to its own Podman service)"
  else
    bad "docker compose plugin missing" "apt-get install docker-compose-plugin (client only, the Docker daemon may stay off)"
  fi
fi

# ---- 2 ---------------------------------------------------------------------
phase "GPU and driver"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  bad "nvidia-smi not found: NVIDIA driver not installed" "install the NVIDIA driver >= ${LW_MIN_DRIVER} (not done by this script)"
  DRIVER=""
else
  IFS=, read -r GPU_NAME VRAM DRIVER < <(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits | head -1)
  GPU_NAME="${GPU_NAME# }" VRAM="${VRAM// /}" DRIVER="${DRIVER// /}"
  note "${GPU_NAME}, ${VRAM} MiB, driver ${DRIVER}"
  if [[ "${DRIVER%%.*}" -ge "${LW_MIN_DRIVER}" ]]; then ok "driver ${DRIVER} >= ${LW_MIN_DRIVER} (vLLM v0.31 images use CUDA 13)"; else
    bad "driver ${DRIVER} < ${LW_MIN_DRIVER}" "upgrade the NVIDIA driver to >= ${LW_MIN_DRIVER}"
  fi
  if [[ "${VRAM}" =~ ^[0-9]+$ && "${VRAM}" -ge "${LW_MIN_VRAM_MIB}" ]]; then ok "VRAM ${VRAM} MiB >= ${LW_MIN_VRAM_MIB}"; else
    bad "VRAM ${VRAM} MiB < ${LW_MIN_VRAM_MIB}" "the lab model needs a GPU with >= ${LW_MIN_VRAM_MIB} MiB"
  fi
fi

# ---- 3 ---------------------------------------------------------------------
phase "Rootless Podman"
if command -v podman >/dev/null 2>&1; then
  ok "$(podman --version)"
else
  bad "podman not found" "apt-get install podman"
fi
for f in ${LW_SUBID_FILES}; do
  if grep -q "^${LAB_USER}:" "${f}" 2>/dev/null; then ok "${f}: ${LAB_USER} has a subordinate ID range"; else
    bad "${f}: no range for ${LAB_USER} (rootless containers cannot start)" "usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${LAB_USER}"
  fi
done

# ---- 4 ---------------------------------------------------------------------
phase "NVIDIA Container Toolkit"
if command -v nvidia-ctk >/dev/null 2>&1; then
  ok "$(nvidia-ctk --version 2>/dev/null | head -1)"
elif can_fix; then
  if ! apt-cache policy nvidia-container-toolkit 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    fix "adding NVIDIA's signed apt repository"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
      gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg &&
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
        >"${LW_TOOLKIT_REPO_LIST}" && apt-get update -q >/dev/null
  fi
  fix "apt-get install nvidia-container-toolkit"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -q nvidia-container-toolkit >/dev/null; then
    did "nvidia-container-toolkit installed"
  else
    bad "apt-get install nvidia-container-toolkit failed" "check apt output (free space on /usr?)"
  fi
else
  bad "nvidia-ctk not found" "sudo make lab-setup (installs nvidia-container-toolkit)"
fi

# ---- 5 ---------------------------------------------------------------------
phase "CDI spec (how rootless Podman hands the GPU to a container)"
cdi_current() { [[ -f "${LW_CDI_SPEC}" ]] && { [[ -z "${DRIVER}" ]] || grep -q "${DRIVER}" "${LW_CDI_SPEC}"; }; }
if cdi_current; then
  ok "${LW_CDI_SPEC} matches driver ${DRIVER:-?}"
elif can_fix && command -v nvidia-ctk >/dev/null 2>&1; then
  [[ -f "${LW_CDI_SPEC}" ]] && fix "${LW_CDI_SPEC} was generated for another driver: regenerating"
  mkdir -p "$(dirname "${LW_CDI_SPEC}")"
  if nvidia-ctk cdi generate --output="${LW_CDI_SPEC}" >/dev/null 2>&1 && cdi_current; then
    did "${LW_CDI_SPEC} generated"
  else
    bad "nvidia-ctk cdi generate failed" "sudo nvidia-ctk cdi generate --output=${LW_CDI_SPEC}"
  fi
elif [[ -f "${LW_CDI_SPEC}" ]]; then
  bad "${LW_CDI_SPEC} is for another driver than ${DRIVER} (stale after a driver update)" "sudo make lab-setup (regenerates it)"
else
  bad "no CDI spec at ${LW_CDI_SPEC}" "sudo make lab-setup (generates it)"
fi

# ---- 6 ---------------------------------------------------------------------
phase "Lab directory ${LAB_DIR}"
if [[ -d "${LAB_DIR}" && "$(stat -c %U "${LAB_DIR}")" == "${LAB_USER}" ]]; then
  ok "exists, owned by ${LAB_USER}"
elif can_fix; then
  if [[ -d "${LAB_DIR}" ]]; then
    fix "${LAB_DIR} exists but is owned by $(stat -c %U "${LAB_DIR}"): giving it to ${LAB_USER} (directory itself only)"
    chown "${LAB_USER}:${LAB_GROUP}" "${LAB_DIR}" && chmod 0700 "${LAB_DIR}" && did "${LAB_DIR} owned by ${LAB_USER}"
  else
    install -d -m 0700 -o "${LAB_USER}" -g "${LAB_GROUP}" "${LAB_DIR}" && did "${LAB_DIR} created for ${LAB_USER}"
  fi
else
  bad "${LAB_DIR} missing or not owned by ${LAB_USER}" "sudo make lab-setup (or LAB_DIR=/other/path for every lab command)"
fi

# ---- 7 ---------------------------------------------------------------------
phase "Disk space"
# Existing parent of LAB_DIR, so the check works before the directory exists.
d="${LAB_DIR}"
while [[ ! -d "${d}" ]]; do d="$(dirname "${d}")"; done
free_gb="$(df -P --block-size=1G "${d}" | awk 'NR == 2 {print $4}')"
mount="$(df -P "${d}" | awk 'NR == 2 {print $6}')"
if [[ -n "$(find "${LAB_DIR}/containers/storage/overlay-images" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  need="${LW_LAB_RERUN_GB}"
  note "images already in the lab store: need ${need} GB for a re-run"
else
  need="${LW_LAB_FIRST_RUN_GB}"
  note "first run: images (~11.4 GB compressed, about twice that unpacked) + model 1.75 GB + scratch = ~${need} GB (estimate)"
fi
if [[ "${free_gb}" -ge "${need}" ]]; then
  ok "${free_gb} GB free on ${mount} (LAB_DIR), need ${need}"
else
  bad "${free_gb} GB free on ${mount}, need ${need} GB" \
    "free $((need - free_gb)) GB on ${mount}, or put the lab on a bigger filesystem: LAB_DIR=/path make lab-check (then lab-setup, lab-gpu with the same LAB_DIR)"
  note "largest filesystems with free space (cloud-sync, backup and boot mounts left out):"
  df -P --block-size=1G -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null |
    awk 'NR > 1 {print $4, $6}' |
    grep -viE ' /(boot|.*(sync|onedrive|dropbox|nextcloud|timeshift|backup|snapshot)).*' | sort -rn | head -3 | while read -r g m; do note "  ${g} GB free on ${m}"; done
fi

# ---- 8 ---------------------------------------------------------------------
phase "Ports on this machine"
busy=()
for p in ${LW_LAB_PORTS}; do
  ss -Hltn "sport = :${p}" 2>/dev/null | grep -q . && busy+=("${p}")
done
if [[ "${#busy[@]}" -eq 0 ]]; then ok "free: ${LW_LAB_PORTS}"; else
  bad "in use: ${busy[*]}" "stop what listens there (ss -ltnp 'sport = :${busy[0]}'), or a previous lab: tests/lab/podman-service.sh stop"
fi

# ---- Summary ------------------------------------------------------------------
printf '\n%s' "${B}" >&2
if [[ "${problems}" -eq 0 ]]; then
  printf 'Lab ready%s%s. Next, WITHOUT sudo:  make lab-gpu   (or make lab-gpu KEEP=1)\n' \
    "$([[ "${fixed}" -gt 0 ]] && echo " (${fixed} item(s) fixed now)")" "${N}" >&2
  exit 0
fi
printf '%d problem(s) left%s:%s\n' "${problems}" "$([[ "${fixed}" -gt 0 ]] && echo ", ${fixed} fixed now")" "${N}" >&2
printf '  - %s\n' "${TODO[@]}" >&2
exit 1
