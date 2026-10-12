# ADR-014: Client Contract for Agents (Hybrid Lane from AiAgentInfrastructure)

**Status:** Accepted 2026-10-12. Implemented in this repository: tool calling and parsers per profile, ≥ 64k context in production profiles, per-key rpm/tpm/parallel limits and token pricing, tool-call smoke test. Open: the matching ADR in AiAgentInfrastructure; DEC-010. Cross-repo: needs a superseding ADR in AiAgentInfrastructure for its `docs/BIOME-L40S.md`.

## Context

- AiAgentInfrastructure (single-maintainer agent setup: LiteLLM gateway with an `auto` chain local → Anthropic → OpenRouter) has a "BIOME" lane that expects a vLLM server with GPU 0 only, model `biome-coder`, 128k context, mTLS from step-ca and vLLM's own API key. Its ADR-0012 says the multi-tenant service lives in a separate repository. **This is that repository**, and it serves something different (R3-06).
- This platform does not serve agents today: tool calling is off in vLLM (R3-02), context is 16k (R3-04), and there are no per-key rate limits (R3-03).
- The owner's topology (ADR-012, ADR-015): this platform is the only LLM server, and the other host is for TensorFlow, not LLM serving.

## Decision

The platform publishes one contract, and AiAgentInfrastructure's BIOME lane becomes an ordinary client of it.

| Item | Contract |
| :-- | :-- |
| Endpoint | `https://<PUBLIC_HOSTNAME>:8443/v1` (ingress, `/v1/*` only), certificate from the institutional step-ca (ADR-011 phase "institutional CA", PLAN P7) |
| Auth | one LiteLLM virtual key per agent host, `--models lifewatch-chat`, with `rpm_limit`, `tpm_limit`, `max_parallel_requests` and expiry (`scripts/ops/issue-key.sh`) |
| Optional second factor | mTLS with step-ca client certificates on 8443 for machine clients (**DEC-010**, decided by IT Security; off by default) |
| Model | alias `lifewatch-chat`. The underlying model depends on the profile (ADR-012) |
| Capabilities guaranteed in every validated profile | OpenAI tool calling with `tool_choice: auto`; streaming; context ≥ 64k tokens (target, checked at validation); reasoning content separated when the model emits it |
| Published facts | `GET /v1/models` lists the alias; the per-profile context limit is in `docs/requirements/PRD.md` §2 and the CHANGELOG |
| Fair use | limits per key; agents are the clients most likely to saturate the GPUs, so their keys get a lower `max_parallel_requests` than the UI key |

Implementation in this repository: profile variables `VLLM_TOOL_CALL_PARSER` and `VLLM_REASONING_PARSER`, passed as `--enable-auto-tool-choice --tool-call-parser …` (`hermes` for Qwen2.5, `qwen3_coder` for Qwen3-Coder / Qwen3.6), checked by a policy test. The smoke test (lab) and the integration test (fake backend) both perform a tool-call round trip.

## Alternatives considered

- **A separate vLLM instance for agents on GPU 0** (AiAgentInfrastructure's design): it bypasses the gateway's keys, limits and audit, doubles the TLS setup, and on a one-GPU host it leaves nothing for researchers.
- **mTLS as the only auth for agents:** good machine identity, but per-client limits and spend attribution live in LiteLLM keys anyway. It stays an optional layer (DEC-010).

## Consequences

- Positive: one server, one audit trail, one upgrade path. Agents get tool calling and long context, and researchers get the same model improvements.
- Negative: agents and researchers share the GPUs, so limits must be tuned from measurements (P5), and an agent burst raises everyone's latency. AiAgentInfrastructure must change its lane: model name, auth header, and the stunnel sidecar only if DEC-010 enables mTLS.
- The contract is a promise: a profile that cannot serve ≥ 64k with tool calling **fails validation** (ADR-012 §3).
