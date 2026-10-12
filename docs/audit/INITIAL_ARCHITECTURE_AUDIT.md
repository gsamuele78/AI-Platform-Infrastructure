# Initial Architecture Proposal Audit: LifeWatch AI Platform

> **Superseded in part (2026-10-09):** the replacement model id it recommends (`Qwen/Qwen2.5-72B-Instruct-FP8`) does not exist, and the 32k context does not fit. See [PRODUCTION_READINESS_AUDIT.md](PRODUCTION_READINESS_AUDIT.md) F-01/F-02.

## Executive Summary
An exhaustive technical audit of the initial architecture proposal (`Guida_Architettura_AI_LifeWatch.html`) reveals critical technical inaccuracies, mathematically impossible hardware assumptions, and security vulnerabilities that prevent deployment in a production environment without significant refactoring.

## Detailed Findings & Claim Verification Matrix

| Claim / Component in Initial Proposal | Status | Technical Reality & Evidence | Required Engineering Correction |
| :--- | :--- | :--- | :--- |
| Deploy `neuralmagic/DeepSeek-V3-FP8` on 2x NVIDIA L40S (96 GB VRAM) | **INCORRECT / IMPOSSIBLE** | DeepSeek-V3 contains 671 billion parameters. At 8-bit precision (FP8), weight memory alone requires ~$671\text{ GB}$. The target host has 96 GB total VRAM. | Replace with `Qwen2.5-72B-Instruct-FP8` ($TP=2$) or `Meta-Llama-3.3-70B-Instruct-FP8` ($TP=2$). |
| DeepSeek-V3 FP8 download size is "circa 65 GB" | **INCORRECT** | A 65 GB download corresponds to a ~65B–70B model. DeepSeek-V3 FP8 is ~671 GB. | Update project documentation to reflect 70B parameter models (~70 GB download). |
| NVIDIA L40S lacks physical NVLink; interconnect is PCIe | **VERIFIED** | L40S uses the Ada Lovelace architecture without physical NVLink bridges. Inter-GPU communication occurs via PCIe Gen4/Gen5. | Enforce Tensor Parallelism ($TP=2$) for models $>48\text{ GB}$. Use independent $TP=1$ replicas for models $\le 32\text{B}$. |
| vLLM PagedAttention prevents KV cache memory fragmentation | **VERIFIED** | Dynamic block allocation in vLLM optimizes KV cache VRAM utilization during high concurrency. | Retain vLLM v0.6.3+ as the primary inference runtime. |
| Compose configuration using `latest` tags and `--trust-remote-code` | **UNSAFE** | Floating tags yield non-reproducible builds. Unvetted remote code execution exposes the container host to arbitrary code execution. | Pin container image digests/versions and disable `--trust-remote-code`. |
| Single shared API key (`vllm-free-key`) without identity mapping | **UNSAFE** | Shared credentials prevent user auditing, rate limiting, and role-based access control (RBAC). | Deploy LiteLLM Proxy integrated with LifeWatch ERIC Keycloak OIDC. |
