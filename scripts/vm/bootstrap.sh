#!/usr/bin/env bash
# Prepare an Ubuntu 24.04 guest: NVIDIA datacenter driver, Docker Engine and
# NVIDIA Container Toolkit, all from signed apt repositories. Idempotent.
#   sudo scripts/vm/bootstrap.sh
# Env: LW_NVIDIA_DRIVER_BRANCH (default 580, the long-term branch; the vLLM
#      v0.31 image is built on CUDA 13.0, which needs a >= 580 driver).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

: "${LW_OS_RELEASE:=/etc/os-release}"
: "${LW_APT_SOURCES_DIR:=/etc/apt/sources.list.d}"
: "${LW_KEYRINGS_DIR:=/etc/apt/keyrings}"
: "${LW_DOCKER_DAEMON_JSON:=/etc/docker/daemon.json}"
: "${LW_NVIDIA_DRIVER_BRANCH:=580}"

require_root

os_field() { grep -E "^$1=" "${LW_OS_RELEASE}" | cut -d= -f2 | tr -d '"'; }
[[ "$(os_field ID)" == ubuntu && "$(os_field VERSION_ID)" == 24.04 ]] ||
  die "Supported guest OS is Ubuntu 24.04 LTS (ADR-001); found $(os_field ID) $(os_field VERSION_ID)"
CODENAME="$(os_field VERSION_CODENAME)"
ARCH="$(dpkg --print-architecture)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg jq ubuntu-drivers-common

mkdir -p "${LW_KEYRINGS_DIR}" "${LW_APT_SOURCES_DIR}"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${LW_KEYRINGS_DIR}/docker.asc"
chmod a+r "${LW_KEYRINGS_DIR}/docker.asc"
echo "deb [arch=${ARCH} signed-by=${LW_KEYRINGS_DIR}/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  >"${LW_APT_SOURCES_DIR}/docker.list"

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
  gpg --batch --yes --dearmor -o "${LW_KEYRINGS_DIR}/nvidia-container-toolkit.gpg"
echo "deb [signed-by=${LW_KEYRINGS_DIR}/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /" \
  >"${LW_APT_SOURCES_DIR}/nvidia-container-toolkit.list"

apt-get update -q
RUNTIME_PKGS=(docker-ce docker-ce-cli containerd.io docker-compose-plugin nvidia-container-toolkit)
apt-get install -y -q "${RUNTIME_PKGS[@]}"

# Signed, precompiled kernel modules matched to the running kernel flavour
# (no DKMS rebuild that can silently fail after a kernel update).
ubuntu-drivers install --gpgpu "nvidia:${LW_NVIDIA_DRIVER_BRANCH}-server"
apt-get install -y -q "nvidia-utils-${LW_NVIDIA_DRIVER_BRANCH}-server"

# An unattended upgrade of dockerd/containerd restarts every container, i.e. an
# unplanned 10+ minute vLLM reload. Upgrade these only in a maintenance window.
# Only packages actually installed ("ii"): dpkg also knows uninstalled and
# virtual ones, and apt-mark refuses to hold those.
mapfile -t DRIVER_PKGS < <(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' "*nvidia*${LW_NVIDIA_DRIVER_BRANCH}-server*" 2>/dev/null |
  awk '$1 == "ii" {print $2}' || true)
apt-mark hold "${RUNTIME_PKGS[@]}" "${DRIVER_PKGS[@]}" >/dev/null

mkdir -p "$(dirname "${LW_DOCKER_DAEMON_JSON}")"
[[ -f "${LW_DOCKER_DAEMON_JSON}" ]] || echo '{}' >"${LW_DOCKER_DAEMON_JSON}"
before="$(sha256_of "${LW_DOCKER_DAEMON_JSON}")"
nvidia-ctk runtime configure --runtime=docker --config="${LW_DOCKER_DAEMON_JSON}"
if [[ "$(sha256_of "${LW_DOCKER_DAEMON_JSON}")" != "${before}" ]]; then
  info "Docker runtime configuration changed; restarting dockerd"
  systemctl restart docker
fi

pass "Guest bootstrapped (driver branch ${LW_NVIDIA_DRIVER_BRANCH}-server)"
warn "Reboot if the NVIDIA driver was installed or upgraded, then run scripts/verify/vm-check.sh"
info "Not adding users to the 'docker' group: membership is root-equivalent. Operators use sudo."
