# Practices Evaluation: What to Import and What It Is Worth

| | |
| :-- | :-- |
| **Date** | 2026-10-12 |
| **Sources** | [gsamuele78/AiAgentInfrastructure](https://github.com/gsamuele78/AiAgentInfrastructure) @ `d6c4cb6` · [gsamuele78/Infra-Iam-PKI](https://github.com/gsamuele78/Infra-Iam-PKI) @ `23175ab` · [OpenHands org](https://github.com/orgs/OpenHands/repositories) (50 active repos listed via the GitHub API; the 9 relevant ones read: OpenHands-Cloud, software-agent-sdk, extensions, docs, benchmarks, automation, sandbox-server, amd-openhands-playbook, litellm) · vLLM source at tag `v0.31.0` · Hugging Face API |
| **Method** | Every claim below was checked against source or an API response. "Computed" means derived from measured inputs by formula; "unmeasured" means it needs the hardware. Nothing is adopted on a claimed benefit: each item has a metric, a baseline and a pre-registered target ([ADR-013](../adr/ADR-013-measure-before-adopting.md)). |
| **Plan** | [PLAN.md](PLAN.md) (the packages that implement the adopted items) |

Legend: ✅ adopt · 🔧 adapt · ⏳ defer · ❌ reject.

## 1. Licence and reuse boundary

| Source | Licence | Reuse |
| :-- | :-- | :-- |
| AiAgentInfrastructure | MIT | code and text |
| Infra-Iam-PKI | Apache-2.0 | code and text (keep the notice for copied files) |
| OpenHands core, software-agent-sdk, extensions, benchmarks | MIT | code and text |
| **OpenHands-Cloud** | **Polyform Free Trial** (not open source, 30 days/year) | **ideas only**: no file, chart or script is copied |
| OpenHands/litellm | fork of BerriAI/litellm, 0 commits ahead of upstream | nothing to import |

## 2. Findings that are not "best practice" but defects

These came out of the comparison and are bugs in this repository today. They are registered as findings R3-xx in the [audit](../audit/PRODUCTION_READINESS_AUDIT.md#round-3-2026-10-12-cross-repo-and-hybrid-agent-review).

| ID | Finding | Evidence |
| :-- | :-- | :-- |
| R3-01 | CI on `main` is **red**; the audit says it is green. `tests/compose/policy.bats` test 2 expects Compose to name `LITELLM_MASTER_KEY` first, the runner's newer Compose names `POSTGRES_USER` first. | GitHub Actions run of 2026-10-12, job "Unit + policy tests": `not ok 2 compose fails fast when a required secret is missing` |
| R3-02 | **Agents cannot use the platform.** vLLM v0.31.0 defaults `enable_auto_tool_choice=False` and `tool_call_parser=None`; any client sending `tools` with `tool_choice: "auto"` (opencode, OpenHands, Codex, Claude-style clients through LiteLLM) gets an error. | `vllm/entrypoints/launchers/cli_args.py` L113-119 at `v0.31.0`; `compose.yaml` passes neither flag |
| R3-03 | Gateway budgets are probably **always zero** for the self-hosted model: `openai/lifewatch-chat` has no price in LiteLLM's cost map and `config.yaml` sets none, so `max_budget` never trips. No per-key `rpm`/`tpm`/`max_parallel_requests` either, so one client can saturate both GPUs. | `configs/proxy/config.yaml`, `scripts/ops/issue-key.sh`; to be confirmed by an integration test (P3), not assumed |
| R3-04 | 16k context is below what coding agents send: OpenHands' local-LLM guide asks for ≥ 22k, 32k recommended. With the 72B on 2 × L40S there is no headroom to raise it (PRD §2). | docs.openhands.dev `usage/llms/local-llms` |
| R3-05 | The topology now has 1 **or** 2 L40S, but the GPU count of 2 is hard-coded: `LW_EXPECTED_GPUS=2` (PVE preflight), `vm-check.sh`, AC-1.1, AC-2.1, and `configure-passthrough.sh` passes every matching GPU (no subset). | `scripts/lib/pve.sh` L15, `scripts/verify/vm-check.sh` L25 |
| R3-06 | The two repos describe incompatible BIOME servers: AiAgentInfrastructure expects GPU 0 only, `biome-coder`, 128k, mTLS, vLLM's own key; this repo serves `lifewatch-chat`, 16k, TLS + LiteLLM virtual keys. The agent lane would fail on model name, context and tool calls. | `AiAgentInfrastructure/docs/BIOME-L40S.md` vs `compose.yaml`, `release.env` |
| R3-07 | Committed junk in a **public** repo: `tests/integration/__pycache__/*.pyc`, `.omo/run-continuation/*.json` (session state of an agent plugin). | `git ls-files` |
| R3-08 | No agent context and no agent guardrails: no `AGENTS.md`, no `.claude/settings.json`. An agent session can read `.env`, `TLS_DIR` keys, backups and the local `tests/vagrant/.vagrant/**/private_key`. | repository tree |
| R3-09 | No dependency update bot and no CVE scan; the images are pinned by digest, so without a bot they age silently. | no `.github/dependabot.yml`, no Trivy |

## 3. Evaluation matrix

"Gain" is what the metric is expected to show; the number is the pre-registered target. Cost is maintenance for a single maintainer.

### 3.1 From AiAgentInfrastructure

| # | Practice | Here today | Verdict | Metric · baseline → target | Cost | Package |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| A1 | `AGENTS.md` as the single agent context, `CLAUDE.md` points to it (ADR-0013 there) | none | ✅ | agent context files: 0 → 1 (+ pointer); invariants listed there are each enforced by a test | low | P0 |
| A2 | Invariants table enforced by tests, **every check born with a mutation test** | 135 bats tests, 0 mutation tests on policy checks | ✅ | policy checks with a mutation case: 0 % → 100 % | medium, one-off | P2 |
| A3 | Measure-before-adopting protocol (ADR-0021 there): pre-registration, ≥ 5 runs, median + IQR, guard metrics | none | ✅ adapted to inference metrics | every adoption decision has a filled register row | discipline | [ADR-013](../adr/ADR-013-measure-before-adopting.md) |
| A4 | Model decided by detected hardware, from a reviewed table, with rollback (ADR-0023 there) | one fixed profile per env file | 🔧 the table holds only **validated** profiles; unknown hardware refuses to deploy | detection correct on fixtures: — → 100 %; deploy on unvalidated hardware: possible → refused | medium | P4, [ADR-012](../adr/ADR-012-gpu-profiles-from-hardware-detection.md) |
| A5 | Dependabot with cooldown, groups, `postgres` major ignored, action SHAs | none | ✅ | pinned components tracked by a bot: 0/8 → ≥ 7/8 | low | P1 |
| A6 | "Known traps" table in `AGENTS.md` | lessons only in audit prose | ✅ seeded from F-01…F-26, R2-05…R2-07, R3-xx | — | low | P0 |
| A7 | Client contract per lane (`api_base`, model, auth) | undocumented | ✅ | see R3-06 | low | P3, [ADR-014](../adr/ADR-014-agent-client-contract.md) |
| A8 | Golden tasks with **deterministic** checks (L6 evals) | DEC-007 "representative prompts", no harness | 🔧 eval set for model selection and FP8-KV acceptance; tool-call tasks checked by schema, not by an LLM judge | — | medium | P5 |
| A9 | Repo-level `.serena/project.yml` without `language_servers` breaks Serena 1.7.0 (their A15) | this repo's file was generated by `serena project create` | — nothing to do | — | — | — |

### 3.2 From Infra-Iam-PKI

| # | Practice | Here today | Verdict | Metric · baseline → target | Cost | Package |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| B1 | `security-scan.yml`: gitleaks on the PR range + weekly full history; Trivy config (blocking HIGH/CRITICAL) + Trivy images (report-only, counts in the job summary) | gitleaks full-history per push | ✅ | images with a weekly CVE count: 0/6 → 6/6; config HIGH/CRITICAL: unmeasured → 0 | low | P1 |
| B2 | `.claude/settings.json` `permissions.deny` on secrets | none | ✅ adapted to `.env`, `TLS_DIR`, `BACKUP_DIR`, `*.pem`, `**/.vagrant/**` | secret globs readable by an agent: all → 0 (static check + mutation) | low | P0 |
| B3 | **step-ca with ACME provisioner** (on by default there) | DEC-002 open: no public DNS / port 80 | ✅ as the internal CA path: certbot `--server <step-ca>/acme/acme/directory` reuses `tls-letsencrypt.sh` | see R3-10 below; renewal tested with 24 h certificates | low | P7 |
| B4 | Keycloak realm in Infra-IAM | DEC-001 open | ✅ write the OIDC client spec here, apply it there | AC-3.4 signed | low | P8 |
| B5 | HC-01: memory **and** cpus limits | memory on 4/5 services, cpus on 0/5 | ✅ for gateway, UI, DB, ingress; vLLM exempt (owns the VM, same exception as AiAgentInfrastructure) | services with both limits: 0/4 → 4/4 | low | P1 |
| B6 | HC-02: bind mounts only | named volumes + tested `pg_dump`/archive backup | ❌ same reasoning as AiAgentInfrastructure ADR-0022: the backup path is tested, bind mounts bring postgres UID handling | — | — | — |
| B7 | `.ai/project.yml` + generator for 6 agent files | — | ❌ one `AGENTS.md` is read by every client in use | — | — | — |
| B8 | CHANGELOG + SemVer tags | release snapshots by git SHA | 🔧 user-visible CHANGELOG at go-live (model and context changes affect researchers); no release-please | — | low | P10 |
| B9 | yamllint / markdownlint / hadolint | shellcheck + compose render | 🔧 yamllint only (compose, LiteLLM config, workflows); no Dockerfiles here; markdownlint ❌ | — | low | P1 |
| B10 | Vagrant lab tiers | already here (LAB.md levels 1-3) | — | — | — | — |
| R3-10 | **Cross-repo risk**: step-ca leaf default is 24 h (Infra-Iam-PKI CONTINUATION-PLAN W5). This repo's renewal timer runs twice a day, certbot renews at < 30 days and preflight warns at < 14 days: with 24 h certs that is one missed run from expiry and a permanent warning. | — | ✅ thresholds become a fraction of the certificate lifetime; ask Infra-Iam-PKI for a 7-30 d provisioner | P7 |

### 3.3 From OpenHands

| # | Practice | Source | Here today | Verdict | Metric · baseline → target | Package |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| C1 | vLLM with `--enable-auto-tool-choice --tool-call-parser <p>` (+ `--reasoning-parser` for thinking models) | docs `local-llms`, Qwen model cards | off (R3-02) | ✅ parser per profile (`hermes` Qwen2.5, `qwen3_coder` Qwen3-Coder/3.6) | tool-call requests answered with a schema-valid call (lab, 50 requests): 0 % → ≥ 95 % (plumbing, not model quality) | P3 |
| C2 | MoE "A3B" models for agentic work (OpenHands recommends Qwen3.6-35B-A3B since 2026-05) | docs `local-llms` | dense 72B, 2024 | 🔧 **candidate**, decided by P5 measurement, not by recommendation | see §4 | P5 |
| C3 | `--enable-prefix-caching` | docs `local-llms` | already **on by default** in v0.31.0 for generative models (`arg_utils.py` L2956) | — no change; recorded so nobody "adds" it as a gain | — | — |
| C4 | Prefix cache shared across tenants | vLLM | shared | ⏳ check `cache_salt` per key (timing side channel between tenants on shared prefixes); unverified at v0.31.0 | — | P3 (check only) |
| C5 | Speculative decoding (MTP `qwen3_next_mtp`, suffix decoding) | Qwen3.6 card, docs (ArcticInference) | none | ⏳ after P5; only with a guard on throughput at full concurrency | output tok/s at concurrency 1: +≥ 20 %; guard: throughput at 32 concurrent ≥ −10 % | P5 follow-up |
| C6 | Upgrade/rollback that **discovers the schema delta** (Alembic head) before deciding (OpenHands-Cloud `upgrade-rollback-runbook` skill, idea only) | OpenHands-Cloud | restores data whenever a stateful **image** changed (ADR-010) | ✅ compare LiteLLM `_prisma_migrations` and Open WebUI migration heads before/after; restore only if a head moved | writes lost on rollback without migration: all since pre-deploy backup → 0; with migration: restored (unchanged) | P9 |
| C7 | E2E test that budgets/limits are **enforced** (OpenHands-Cloud `budget-e2e`, idea only) | OpenHands-Cloud | none | ✅ integration asserts 429 on rpm/parallel limits and the budget behaviour of R3-03 | test exists and goes red when limits are removed | P3 |
| C8 | Secret/config checksum forces a restart | OpenHands-Cloud | release dir per deploy changes every bind-mount source; env changes recreate | — already covered | — | — |
| C9 | `.agents/skills/<name>/SKILL.md` with frontmatter, progressive disclosure | software-agent-sdk, extensions | none | ✅ three repo skills: `image-upgrade` (RUNBOOK §8 + C6), `release-record` (AC-3.1), `gpu-passthrough-change` | each skill's referenced scripts/flags exist (static check) | P11 |
| C10 | ConfirmRisky: confirmation on high-risk actions | software-agent-sdk security | none | ✅ as Claude Code `permissions.ask` on `--apply`, deploy, rollback, restore, `qm`, `docker compose down -v` | destructive commands without confirmation: all → 0 (static check + mutation) | P0 |
| C11 | Release security scan with OSV on dependency diffs | software-agent-sdk | — | ❌ our dependencies are images: B1 (Trivy) covers them | — | — |
| C12 | Adopt OpenHands / OpenHands-Cloud as a product here | — | — | ❌ out of scope (agents live in AiAgentInfrastructure, which already rejected it in its ADR-0019); OpenHands-Cloud is not open source | — | — |

## 4. Model candidates, computed from measured sizes

> **Superseded the same day** by [MODEL_SELECTION.md](MODEL_SELECTION.md), which adds the 2026 releases this table missed (Qwen3.8-27B, Gemma 4, gpt-oss) and proposes one model for both profiles.

Inputs measured on 2026-10-12 from the Hugging Face API (safetensors sum, `config.json` at the listed revision). Budget per L40S: 46,068 MiB × 0.90 = **40.5 GiB**. Activations and CUDA graphs are estimated at 1.5-2.5 GiB per GPU (as in PRD §2). Hybrid models (Qwen3.6, Qwen3-Coder-Next) keep a per-token KV cache only on their full-attention layers (1 in 4). Their linear-attention layers hold a fixed state per sequence instead, estimated at about 30 MiB per sequence.

| Model (revision) | Weights | Active params | KV/token (BF16) | Profile | KV left (computed) | Max context it can serve | Tool parser | Licence |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| RedHatAI/Qwen2.5-72B-Instruct-FP8-dynamic (`4d9910ef`) | 75.2 GB | 72B | 320 KiB (160 FP8) | 2 GPU | 6-8 GiB | 16k (chosen), ~40-50k tokens total | `hermes` | Qwen |
| Qwen/Qwen3.6-35B-A3B-FP8 (`95a723d0`) | 37.5 GB | 3B | 20 KiB | 2 GPU | ~40 GiB | full 262k, ~2M tokens total | `qwen3_coder` + reasoning `qwen3` | Apache-2.0 |
| same | | | | **1 GPU** | ~2-3 GiB after per-sequence states | ~100-150k tokens total: **marginal**, must be measured | | |
| Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 (`dcaee4d4`) | 31.2 GB | 3B | 96 KiB (48 FP8) | **1 GPU** | ~9.5 GiB | ~100k tokens total (BF16 KV), ~200k (FP8 KV) | `qwen3_coder` | Apache-2.0 |
| Qwen/Qwen3-32B-FP8 (`aa55da1e`) | 34.3 GB | 32B dense | 256 KiB | 1 GPU | ~6.5 GiB | ~27k tokens total: **rejected** for 1 GPU (dense, slow, small KV) | `hermes` | Apache-2.0 |
| Qwen/Qwen3-Coder-Next-FP8 (`da6e2ed2`) | 80.4 GB | 3B | 24 KiB | 2 GPU | ~1-2 GiB | marginal: **rejected** unless measured | `qwen3_coder` | Apache-2.0 |
| RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic (`f50dbad2`) | 72.7 GB | 70B | 320 KiB | 2 GPU | ~8-10 GiB | same class as the 72B | `llama3_json` | Llama 3.3 |

What this does and does not show:

- **Capacity:** on two GPUs a 3B-active MoE leaves about 5× more KV memory than the 72B and serves 16× the context. On one GPU only the MoE models fit at all. These are computed numbers: vLLM's `# GPU blocks` log line on the host is the measurement (AC-3.1).
- **Speed:** decode cost scales with active parameters (3B vs 72B), so a large throughput gain is *expected*. It is **unmeasured** until P5 runs `vllm bench serve` on the L40S.
- **Quality:** nothing here says Qwen3.6 answers researchers better than Qwen2.5-72B. That is the eval set in P5 (DEC-007, DEC-009), with a guard of no regression beyond tolerance.

## 5. Not imported, and why (summary)

Generators of agent files (B7), bind-mount-only storage (B6), markdownlint, release-please, OpenHands as a product, OpenHands-Cloud code (licence), the litellm fork (no delta), OSV-on-diff (no language dependencies here).
