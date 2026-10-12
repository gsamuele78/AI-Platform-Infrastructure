# ADR-003: vLLM Engine Selection & Topology Strategy

**Status:** Accepted, amended 2026-10-09 (see Amendment).

## Context
Multi-user serving requires efficient KV cache memory management and FP8 CUDA kernel execution without NVLink bridges.

## Decision
Standardize on **vLLM v0.6.3+**. Deploy 70B/72B models using Tensor Parallelism ($TP=2$) across both GPUs, and 32B models using independent $TP=1$ replicas on GPU 0 and GPU 1.

## Rationale
PagedAttention eliminates KV cache memory fragmentation. Continuous batching maximizes throughput under multi-user workloads. Independent 32B replicas avoid PCIe synchronization latency.

## Consequences
Model parameter counts are strictly bounded by total available VRAM (96 GB).

## Amendment (2026-10-09)
- The 72B (TP=2) deployment and the two 32B TP=1 replicas are **alternative profiles**, not concurrent: each needs both GPUs.
- KV headroom at TP=2 is only about 6-8 GiB (PRD §2). The release uses `--kv-cache-dtype fp8` and `--max-model-len 16384`; with a BF16 KV cache a 32k context cannot start.
- No NVLink and a virtualised PCIe root complex: NCCL P2P and vLLM custom all-reduce stay disabled until `nvidia-smi topo -p2p r` shows OK inside the guest.
