#!/usr/bin/env bash
# Guest acceptance gate: every passed-through L40S visible with full memory, and reachable
# from containers through the NVIDIA runtime. Exit 1 on any failure.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Default: every L40S on the PCI bus (1 or 2, ADR-012) must work. Set it to
# check an exact count instead.
: "${LW_EXPECTED_GPUS:=}"
: "${LW_GPU_PCI_ID:=10de:26b9}"
# An L40S reports 46068 MiB; anything well below means the wrong card or a
# vGPU/MIG slice.
: "${LW_MIN_GPU_MIB:=45000}"
# Docker: --gpus all. Podman (CDI only): --device nvidia.com/gpu=all
: "${LW_GPU_DEVICE_ARGS:=--gpus all}"
# Same CUDA major as the vLLM image: if this runs, the driver is new enough.
CUDA_IMAGE="nvidia/cuda:13.0.2-base-ubuntu24.04@sha256:2ab6381d970b211fb93853796dc6707eb8a72575a375c422b17cf4d8b2641701"

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found: NVIDIA driver not installed (scripts/vm/bootstrap.sh)"

if [[ -z "${LW_EXPECTED_GPUS}" ]]; then
  command -v lspci >/dev/null 2>&1 || die "lspci not found (apt-get install pciutils)"
  LW_EXPECTED_GPUS="$(lspci -n -d "${LW_GPU_PCI_ID}" | grep -c . || true)"
  [[ "${LW_EXPECTED_GPUS}" -ge 1 && "${LW_EXPECTED_GPUS}" -le 2 ]] ||
    die "${LW_EXPECTED_GPUS} GPU(s) with PCI ID ${LW_GPU_PCI_ID} on the bus; this platform supports 1 or 2 L40S (check the VM's hostpci entries)"
  info "${LW_EXPECTED_GPUS} L40S on the PCI bus"
fi

errors=0
mapfile -t gpus < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits)
if [[ "${#gpus[@]}" -eq "${LW_EXPECTED_GPUS}" ]]; then
  pass "${#gpus[@]} GPU(s) visible"
else
  fail "${#gpus[@]} GPU(s) visible, expected ${LW_EXPECTED_GPUS}"
  errors=1
fi
for g in "${gpus[@]}"; do
  mib="${g##*, }"
  if [[ "${mib}" =~ ^[0-9]+$ && "${mib}" -ge "${LW_MIN_GPU_MIB}" ]]; then
    pass "${g} MiB"
  else
    fail "GPU '${g}' has ${mib} MiB, expected >= ${LW_MIN_GPU_MIB}"
    errors=1
  fi
done

info "GPU peer-to-peer status (NCCL_P2P_DISABLE stays 1 unless this reports OK):"
nvidia-smi topo -p2p r >&2 || warn "Could not query P2P topology"

read -ra gpu_args <<<"${LW_GPU_DEVICE_ARGS}"
if docker run --rm "${gpu_args[@]}" "${CUDA_IMAGE}" nvidia-smi -L >&2; then
  pass "Containers can access the GPUs"
else
  fail "docker --gpus all failed: check nvidia-container-toolkit (nvidia-ctk runtime configure --runtime=docker)"
  errors=1
fi

[[ "${errors}" -eq 0 ]] || die "Guest GPU verification failed"
pass "Guest GPU verification passed"
