# ADR-002: Dedicated PCIe GPU Passthrough via VFIO

**Status:** Accepted — implemented by `scripts/pve/*` (PCI-ID match, IOMMU isolation check, manifest rollback).

## Context
Two physical NVIDIA L40S 48GB GPUs are installed on the Proxmox VE host. We must choose between vGPU virtualization (NVIDIA GRID) and direct PCIe Passthrough.

## Decision
Utilize direct **PCIe Passthrough (`vfio-pci`)** to assign both physical GPUs exclusively to the dedicated AI VM.

## Rationale
1. Eliminates software licensing overhead associated with NVIDIA vGPU software.
2. Delivers bare-metal CUDA performance and direct DMA memory access.
3. Simplifies driver management within a single guest OS environment.

## Consequences
The hypervisor host cannot use the assigned L40S GPUs for other virtual machines.
