# Product Requirements Document (PRD) — LifeWatch AI Platform

## 1. Product Overview
Provide a secure, multi-tenant, local LLM inference platform running on Proxmox VE hardware for LifeWatch ERIC and BIOME researchers, system engineers and institutional collaborators:

- one Ubuntu 24.04 VM with **one or two NVIDIA L40S** passed through. The guest detects the count and deploys the matching profile ([ADR-012](../adr/ADR-012-gpu-profiles-from-hardware-detection.md));
- a **web chat** (Open WebUI) with institutional login and role-based access from Keycloak ([KEYCLOAK_CLIENT.md](../operations/KEYCLOAK_CLIENT.md));
- an **OpenAI-compatible API** with per-client keys, model allow-lists, rate, concurrency and token-budget limits, usable by scripts, notebooks and coding agents ([ADR-014](../adr/ADR-014-agent-client-contract.md));
- operations an institution can audit: pinned images and model revisions, reversible host changes, release snapshots with automatic rollback, verified backups.

## 2. Memory Sizing

> **2026-10-12:** the production model is now chosen per GPU profile ([MODEL_SELECTION.md](../plan/MODEL_SELECTION.md), DEC-009): Qwen3.8-27B FP8, 64k context on one L40S, 128k on two. The worked 72B budget below stays as the reference for the formula and as the P5 baseline row.

Hybrid-attention models (Qwen3.5/3.6/3.8) keep a per-token KV cache only on their full-attention layers. Their linear-attention layers instead hold a fixed state per running sequence: $2 \times N_{\text{linear}} \times N_{\text{v\_heads}} \times d_k \times d_v$ bytes in BF16, about 72 MiB for Qwen3.8-27B. That state is budgeted per concurrent sequence (`VLLM_MAX_NUM_SEQS`), not per token.

### Agent contract (ADR-014)

Every production profile serves ≥ 64k context with OpenAI tool calling (`tool_choice: auto`) and streaming. The served name is always `lifewatch-chat`.

$$M_{\text{total}} = M_{\text{weights}} + M_{\text{KV}} + M_{\text{activations+CUDA graphs}} + M_{\text{headroom}}$$

KV cache per token (grouped-query attention uses the **KV** heads, not the attention heads):

$$B_{\text{KV/token}} = 2 \times N_{\text{layers}} \times N_{\text{kv\_heads}} \times d_{\text{head}} \times B_{\text{KV dtype}}$$

> Correction (audit F-23): the previous formula used $N_{\text{heads}}$. For Qwen2.5-72B that is 64 instead of 8 and overstated the KV cache 8×.

### Worked budget: Qwen2.5-72B-Instruct FP8 on 2 × L40S

| Quantity | Value | Source |
| :-- | :-- | :-- |
| Usable VRAM per L40S | 46,068 MiB ≈ 45.0 GiB | `nvidia-smi` on an L40S |
| vLLM budget per GPU at `--gpu-memory-utilization 0.90` | 40.5 GiB | |
| Weights | 75.2 GB = 70.0 GiB, i.e. 35.0 GiB per GPU at TP=2 | sum of safetensors, `RedHatAI/Qwen2.5-72B-Instruct-FP8-dynamic@4d9910ef` |
| Activations and CUDA graphs | about 1.5-2.5 GiB per GPU | **estimate** |
| **Left for KV cache** | **about 3-4 GiB per GPU, 6-8 GiB total** | |
| Geometry | 80 layers, 8 KV heads, head dim 128 | model `config.json` |
| KV per token, BF16 / FP8 | 320 KiB / 160 KiB | formula above |
| Cacheable tokens, BF16 | about 19.6k-26k | |
| Cacheable tokens, FP8 KV | about 39k-52k | |

Consequences:

- With a BF16 KV cache, **a single 32,768-token sequence does not fit** and vLLM refuses to start. The original configuration could not have booted.
- Configuration used until 2026-10 (former `release.env`): FP8 KV cache with `max-model-len 16384`. That leaves room for 2-3 maximum-length requests in flight, and many more short ones.
- **Must be confirmed on hardware (AC-3.1):** vLLM logs `# GPU blocks: N`, and the cacheable token count is N × 16.

### Model candidates

| Model | Weights | Strategy | Status |
| :-- | :-- | :-- | :-- |
| DeepSeek-V3 (671B, FP8) | ~671 GB | n/a | **Rejected**: 7× the available VRAM |
| Qwen2.5-72B-Instruct, FP8 W8A8 (`RedHatAI/Qwen2.5-72B-Instruct-FP8-dynamic`) | 75.2 GB measured | TP=2 | Former selection, now the P5 **reference row**: 2-GPU only, 16k context |
| **Qwen3.8-27B FP8** (`Qwen/Qwen3.8-27B-FP8@017b9c7a`) | 30.9 GB measured | TP=1 (`l40s-1`), TP=2 (`l40s-2`) | **Proposed for both profiles** (DEC-009), pending P5 ([MODEL_SELECTION.md](../plan/MODEL_SELECTION.md)) |
| Llama-3.3-70B-Instruct FP8 (`RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`) | not measured | TP=2 | Alternative; same KV geometry. Measure the weights before approving. |
| Qwen2.5-Coder-32B FP8, two TP=1 replicas | not measured | one per GPU | Alternative **profile**, not concurrent with the 72B (both need both GPUs) |

## 3. Functional Requirements

| ID | Requirement | Status |
| :-- | :-- | :-- |
| FR-1 | OpenAI-compatible `/v1/chat/completions` and `/v1/models` | Implemented (LiteLLM → vLLM) |
| FR-2 | Authenticate every request | **Changed (ADR-004):** people authenticate with Keycloak OIDC at Open WebUI; API clients use scoped LiteLLM virtual keys. Validating JWTs at the gateway requires LiteLLM Enterprise (DEC-004). |
| FR-3 | Restrict models and admin functions by role | Web chat: Keycloak client roles → Open WebUI `user`/`admin`, Keycloak groups → Open WebUI groups (model and knowledge sharing), others refused or pending. API: per-key model allow-lists, rpm/tpm/parallel limits and token budgets (OSS). OIDC tokens at the gateway itself still need Enterprise (DEC-004). |
| FR-6 | OpenAI tool calling and ≥ 64k context for agents | Implemented in the profiles (ADR-014); smoke-tested on every deploy |
| FR-7 | Same service on one or two L40S, chosen by hardware | Implemented: profile detection, 1-or-2 GPU passthrough (ADR-012, [PROXMOX_PASSTHROUGH.md](../operations/PROXMOX_PASSTHROUGH.md)) |
| FR-4 | Open WebUI for chat, RAG and sharing | Implemented, behind the TLS ingress (ADR-011) |
| FR-5 | Non-destructive, reversible host and stack changes | Implemented: dry-run by default, manifest-based passthrough rollback, release snapshots with automatic rollback (ADR-009, ADR-010) |
