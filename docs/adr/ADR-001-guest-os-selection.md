# ADR-001: Guest Operating System Selection

**Status:** Accepted — implemented by `scripts/vm/bootstrap.sh` (refuses any other OS).

## Context
The platform requires an enterprise Linux distribution supporting NVIDIA 550.x+ drivers, CUDA 12.4, Docker Engine, and long-term security maintenance.

## Decision
Select **Ubuntu 24.04 LTS Server**.

## Rationale
1. Native support and validation from NVIDIA for Container Toolkit.
2. Kernel 6.8 LTS provides support for modern PCIe device passthrough and memory management.
3. Long-Term Support (LTS) maintenance guaranteed through 2029.

## Consequences
System administrators must verify DKMS module compilation following kernel updates.
