# Product Requirements Document (PRD) — LifeWatch AI Platform

## 1. Product Overview
Provide a secure, multi-tenant, local LLM inference platform running on Proxmox VE hardware for LifeWatch ERIC researchers, system engineers and institutional collaborators.

## 2. Memory Sizing

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
- Chosen configuration (`release.env`): FP8 KV cache with `max-model-len 16384`. That leaves room for 2-3 maximum-length requests in flight, and many more short ones.
- **Must be confirmed on hardware (AC-3.1):** vLLM logs `# GPU blocks: N`, and the cacheable token count is N × 16.

### Model candidates

| Model | Weights | Strategy | Status |
| :-- | :-- | :-- | :-- |
| DeepSeek-V3 (671B, FP8) | ~671 GB | n/a | **Rejected**: 7× the available VRAM |
| Qwen2.5-72B-Instruct, FP8 W8A8 (`RedHatAI/Qwen2.5-72B-Instruct-FP8-dynamic`) | 75.2 GB measured | TP=2 | **Selected, marginal KV headroom** (see above) |
| Llama-3.3-70B-Instruct FP8 (`RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`) | not measured | TP=2 | Alternative; same KV geometry. Measure the weights before approving. |
| Qwen2.5-Coder-32B FP8, two TP=1 replicas | not measured | one per GPU | Alternative **profile**, not concurrent with the 72B (both need both GPUs) |

## 3. Functional Requirements

| ID | Requirement | Status |
| :-- | :-- | :-- |
| FR-1 | OpenAI-compatible `/v1/chat/completions` and `/v1/models` | Implemented (LiteLLM → vLLM) |
| FR-2 | Authenticate every request | **Changed (ADR-004):** people authenticate with Keycloak OIDC at Open WebUI; API clients use scoped LiteLLM virtual keys. Validating JWTs at the gateway requires LiteLLM Enterprise (DEC-004). |
| FR-3 | Restrict models and admin functions by role | Per-key model allow-lists and budgets (OSS). Mapping OIDC groups to gateway roles needs Enterprise (DEC-004). |
| FR-4 | Open WebUI for chat, RAG and sharing | Implemented, behind the TLS ingress (ADR-011) |
| FR-5 | Non-destructive, reversible host and stack changes | Implemented: dry-run by default, manifest-based passthrough rollback, release snapshots with automatic rollback (ADR-009, ADR-010) |
