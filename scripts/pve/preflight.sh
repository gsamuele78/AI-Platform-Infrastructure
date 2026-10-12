#!/usr/bin/env bash
# Read-only Proxmox VE audit for L40S passthrough. Exit 0 = safe to proceed,
# exit 1 = at least one hard failure. Makes no changes to the host.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/pve.sh
source "${LW_REPO_ROOT}/scripts/lib/pve.sh"

case "${1:-}" in
  -h | --help)
    echo "Usage: $0   (env: LW_EXPECTED_GPUS=${LW_EXPECTED_GPUS}, LW_GPU_PCI_ID=${LW_GPU_PCI_ID})"
    exit 0
    ;;
  "") ;;
  *) die "Unknown argument: $1" ;;
esac

info "LifeWatch PVE passthrough preflight (read-only)"
if pve_host_checks; then
  pass "Preflight complete: ${LW_WARNINGS} warning(s), no failures"
else
  die "Preflight failed: fix the [FAIL] items above before configuring passthrough"
fi
