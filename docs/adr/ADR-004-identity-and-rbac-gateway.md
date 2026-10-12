# ADR-004: LiteLLM API Gateway with Keycloak OIDC Authentication

**Status:** Amended 2026-10-09 — the original decision is not deliverable on LiteLLM OSS (see Amendment).

## Context
Raw vLLM endpoints lack authentication, role-based access control, rate limiting, and identity provider integration.

## Decision
Deploy **LiteLLM Proxy** as the unified API gateway in front of vLLM backends, integrated with institutional Keycloak OIDC.

## Rationale
1. Delivers OpenAI-compatible API endpoints while validating OIDC JWT tokens.
2. Enforces per-user, per-group, and per-model access policies.
3. Maintains audit logs and request metrics in PostgreSQL.

## Consequences
API requests incur a negligible latency overhead (~2–5 ms) for token validation.

## Amendment (2026-10-09)
**Finding:** LiteLLM JWT/OIDC authentication (`enable_jwt_auth`) requires a LiteLLM Enterprise licence (docs.litellm.ai/docs/proxy/token_auth). The OSS gateway cannot validate Keycloak tokens, so the decision above cannot be implemented as written.

**Revised decision (OSS):**
1. **People** authenticate with Keycloak OIDC at Open WebUI (`OAUTH_*`, `OPENID_PROVIDER_URL`). Local sign-up is disabled and new users start as `pending`.
2. **Open WebUI** calls the gateway with one scoped virtual key (`scripts/ops/issue-key.sh`). It never holds the master key; preflight enforces this.
3. **API clients** get per-person or per-project virtual keys with model allow-lists, budgets and expiry. Every key is attributable in the spend log.
4. The master key is used only by operators and scripts.

**Consequence:** per-request identity at the gateway is per key, not per OIDC subject. Mapping OIDC groups to gateway roles (FR-3) requires the Enterprise licence (DEC-004).
