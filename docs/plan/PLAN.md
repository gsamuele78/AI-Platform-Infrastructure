# Plan: From Tested Base to Validated Hybrid Platform

| | |
| :-- | :-- |
| **Status** | 2026-10-12: P0, P1, P2, P4 and the code parts of P3 and P8 are merged (PR #1, #3), with integration green in CI. The P5 harness is ready. Lab run pending: the laptop lacks the NVIDIA Container Toolkit, the CDI spec and ~11 GB of disk (`make lab-check`). P5-P11 open; P6, P7 and P10 are on hold until the infrastructure is ready. Replaces the "remaining items" scattered across the [audit](../audit/PRODUCTION_READINESS_AUDIT.md) and [DECISIONS_REQUIRED](../DECISIONS_REQUIRED.md); those files stay the record of what was found and decided. |
| **Inputs** | [PRACTICES_EVALUATION.md](PRACTICES_EVALUATION.md) (sources, findings R3-01…R3-11, what to import) · [MODEL_SELECTION.md](MODEL_SELECTION.md) (models for one and two L40S) |
| **ADRs** | [012](../adr/ADR-012-gpu-profiles-from-hardware-detection.md) GPU profiles · [013](../adr/ADR-013-measure-before-adopting.md) measure before adopting · [014](../adr/ADR-014-agent-client-contract.md) agent client contract · [015](../adr/ADR-015-second-gpu-allocation-by-benchmark.md) second GPU by benchmark |
| **Cloud** | [CLOUD_DEVELOPMENT_PLAN.md](CLOUD_DEVELOPMENT_PLAN.md) (which packages can run in Claude Code cloud sessions) |
| **Rule** | One PR per package. A package is done when its acceptance passes **and** its measurement row is filled in the register (§4), including "target missed" or "not run". |

## 1. Where things stand (verified 2026-10-12)

| Area | State |
| :-- | :-- |
| Repository | Sound tested base: 135 bats tests, 6/6 images pinned by digest, integration lifecycle on real containers, VM test, laptop GPU lab |
| CI on `main` | **Red** (R3-01): one Compose-version-dependent assertion. Every later PR is blind until it is fixed |
| Go-live blockers (unchanged) | AC-3.1 on the L40S host, DEC-002 public trust, DEC-006 off-host backups, DEC-007 FP8 KV accuracy |
| New since the 2026-10-09 audit | Topology is now 1 **or** 2 L40S with hardware-selected profiles (ADR-012); the platform must also serve agents (ADR-014); the second GPU's allocation goes to a benchmark (ADR-015) |
| Not implemented | Observability (ADR-008), LoRA governance (ADR-005) |

### Assumptions (change the plan if wrong)

1. The L40S host and its Proxmox VM are available for **two maintenance windows** in P5 (one per profile).
2. Infra-Iam-PKI's step-ca and Keycloak are reachable from the platform VM (same institutional network), and their maintainer is the same person.
3. Research workloads for the TensorFlow benchmark (P5b) can be named by the research lead, and a GPU is temporarily available to run them (the L40S host itself works).
4. The repository stays **public**: no internal host names, IPs or user names in any committed file. A check enforces this (P2).

## 2. Packages

Order: `P0 → P1 → P2 → P3 → P4 → P5/P5b → DEC-008 → P6 → P7 → P8 → P9 → P10`. P11 can run any time after P0.

### P0. Green CI, hygiene and agent guardrails *(small, cloud-runnable)*: **done locally**

- **Deliverables:**
  - fix R3-01: assert on any of the required variables instead of the first one Compose reports;
  - untrack `tests/integration/__pycache__/` and `.omo/` and add them to `.gitignore` (R3-07);
  - `git rm` the obsolete generators `bootstrap_repo.sh` and `build_lifewatch_platform.sh` (F-25; they are tracked, so the audit note "not in git" is wrong), and the empty `docs/Report`;
  - `AGENTS.md` (context, invariants, known traps seeded from F-xx/R2-xx/R3-xx, commands) plus `CLAUDE.md` pointing to it;
  - `.claude/settings.json`: `permissions.deny` on `.env`, `*.pem`, `*.key`, `**/.vagrant/**`, backups, `TLS_DIR`; `permissions.ask` on `--apply`, `make deploy|rollback`, `restore.sh`, `qm `, `docker compose down -v` (C10);
  - `.editorconfig`.
- **Acceptance:** CI green on all four jobs; a test lists the deny/ask rules and fails if one is removed (mutation).
- **Measure:** CI jobs green 2/4 → 4/4. Destructive commands without confirmation for an agent: all → 0. Secret globs readable: all → 0.
- **Rollback:** `git revert`.

### P1. Supply chain: Dependabot, Trivy, limits *(cloud-runnable)*: **done** except yamllint (Dependabot, Trivy report, `cpus` limits with vLLM exempt)

- **Deliverables:** `.github/dependabot.yml` (docker-compose, github-actions; cooldown 7 days; `postgres` major ignored; one group for minor/patch; vLLM excluded from grouping because every bump is a maintenance window); `security-scan.yml` with gitleaks on the PR range plus weekly full history, Trivy config (blocking HIGH/CRITICAL) and Trivy images (report-only, counts in the job summary, as Infra-Iam-PKI); `cpus` limits on gateway, UI, DB and ingress (HC-01; vLLM exempt with the reason written down); yamllint on compose, configs and workflows.
- **Acceptance:** the first Dependabot PR opens and its CI runs; the Trivy summary lists all 6 images; a policy test requires `cpus` and `memory` on the four services.
- **Measure:** pins tracked by a bot 0/8 (6 images + actions + Makefile tools) → ≥ 7/8. Images with a weekly CVE count 0/6 → 6/6. Services with both limits 0/4 → 4/4.

### P2. Mutation tests for policy checks *(cloud-runnable)*: **done** (`make mutation`, CI job; the internal-names check is still open)

- **Deliverables:** `tests/mutation/` with a catalogue (`catalog.tsv`: check, file, mutation) and a runner that applies each mutation to a temporary copy and expects the matching test to fail. Covers every rule in `policy.bats`, preflight secret checks, and the new P0/P3 checks. Adds the "no internal names in committed files" check (assumption 4).
- **Acceptance:** every catalogued mutation turns its test red, and the runner fails if a mutation survives.
- **Measure:** policy checks with a mutation case 0 % → 100 %; surviving mutations → 0. Runtime of `make test` ≤ +30 % (guard).

### P3. Agent-ready gateway and backend *(cloud-runnable except the lab step)*: **code done**; integration (CI) and lab tool call pending; `cache_salt` check open

- **Deliverables:**
  - profile variables `VLLM_TOOL_CALL_PARSER` / `VLLM_REASONING_PARSER` and the flags in `compose.yaml` (R3-02, C1). The policy test requires the parser whenever auto tool choice is on;
  - `issue-key.sh --rpm --tpm --max-parallel`; per-model price in `litellm_params` (`input_cost_per_token`/`output_cost_per_token`, an internal accounting unit) so budgets are real, or remove the budget claims from the docs (R3-03);
  - integration: the fake backend learns tool calls; tests for a tool-call round trip, 429 on `rpm_limit` and `max_parallel_requests`, and budget behaviour (C7);
  - check whether vLLM v0.31.0 accepts a per-request `cache_salt` and whether LiteLLM can set it per key (C4). Record the result; implement only if both exist;
  - ADR-014 contract published in the PRD.
- **Acceptance:** integration green with the new tests; the lab (`make lab-gpu`, Qwen3.5-0.8B with `qwen3_coder`) completes a real tool call.
- **Measure:** schema-valid tool calls in the lab, 50 requests: 0 % → ≥ 95 % (this proves the plumbing, not model quality). Limit enforcement tests: 0 → 3.

### P4. Hardware-detected profiles (ADR-012) *(cloud-runnable on fixtures)*: **done** (detection time not measured yet)

- **Deliverables:** `profiles/{l40s-1,l40s-2,lab}.env`; `scripts/vm/detect-profile.sh` (GPU count by PCI id, VRAM, compute capability, driver), fixtures for 0/1/2/3 GPUs and other models; preflight and `vm-check.sh` driven by the profile; `LW_EXPECTED_GPUS` ∈ {1,2}; `configure-passthrough.sh --gpu <BDF>` (repeatable) with its bats cases; AC-1.1/2.1/3.1 rewritten per profile; `validated` flag per profile.
- **Acceptance:** fixtures map to the expected profile; unknown hardware refuses; passthrough of a subset is idempotent and rolls back by manifest (existing ADR-009 guarantees hold for a subset).
- **Measure:** correct decisions on fixtures → 100 %. Deploys possible on unvalidated hardware: yes → no (mutation-tested). Detection time < 2 s (`hyperfine`, median of 10).

### P5. Model selection and capacity on the L40S host *(needs the host, two windows)*: **harness ready** ([bench/](../../bench/README.md): load, eval, report, pre-registered `gates.json`, tested); waiting on the host and on the research golden set

- **Deliverables:** `bench/` with
  - **golden set** (owner + research lead): ≥ 40 research prompts with deterministic or rubric-keyed checks (extraction, citation format, R/Python code that must run, Italian and English), plus ≥ 20 agent tasks with tool calls checked by JSON schema;
  - **load profile:** `vllm bench serve` (pinned to the image's version) with fixed input/output lengths at concurrency 1/8/32;
  - **capacity:** `# GPU blocks` from the start-up log.
  Runs: the candidates and challengers in [MODEL_SELECTION.md §6](MODEL_SELECTION.md#6-what-p5-must-measure-before-profile_statusvalidated). `l40s-1`: Qwen3.8-27B vs Gemma 4 26B-A4B and gpt-oss-20b. `l40s-2`: Qwen3.8-27B TP=2 vs two data-parallel replicas and Qwen3.6-35B-A3B, plus Qwen2.5-72B as the reference row. A passing profile gets `PROFILE_STATUS=validated` by PR.
- **Pre-registered gate** (ADR-013): a challenger replaces the baseline in a profile if golden-set quality ≥ baseline −2 pp **and** context ≥ 64k with tool calling (ADR-014) **and** p95 TTFT at concurrency 8 ≤ baseline +20 %. Primary metric: throughput at concurrency 32.
- **Acceptance:** AC-3.1 record committed for each validated profile (model, revision, flags, GPU blocks, eval numbers, run count).
- **Measure:** see the gate. Baseline row = current 72B with FP8 KV at 16k.
- **Rollback:** profiles are files; reverting the PR and redeploying restores the previous model (5-15 min reload).

### P5b. TensorFlow benchmark for the second GPU (ADR-015) *(outside this repo's code)*

- **Deliverables:** ≥ 3 jobs chosen by the research lead, run CPU-only on the target server and on one L40S, ≥ 5 runs each; projected GPU-busy hours per month; result in DEC-008.
- **Gate:** ADR-015 §1 (≥ 5× median speed-up and ≥ 20 % busy) together with §2 (the P5 LLM loss acceptable).

### P6. Observability (ADR-008, finally) *(cloud-runnable except GPU exporter)*

- **Deliverables:** Prometheus + DCGM exporter + vLLM `/metrics` + LiteLLM metrics, pinned and loopback-only; 5 alerts: GPU memory > 95 %, vLLM unhealthy, gateway 5xx rate, certificate expiry (fraction of lifetime, see P7), backup age > 26 h. Grafana ⏳ (not needed for alerts).
- **Measure:** time to detect a stopped vLLM: unknown (until a user complains) → ≤ 2 min, measured by stopping it in the lab. Maintenance cost guard: ≤ 15 min/month.

### P7. Internal CA through step-ca ACME (DEC-002, B3, R3-10)

- **Deliverables:** `tls-letsencrypt.sh --server URL --ca-bundle FILE` (certbot against Infra-Iam-PKI's ACME provisioner); renewal timer hourly when the certificate lifetime is < 7 days; preflight and alert thresholds as a fraction of the lifetime (warn at 1/3 remaining) instead of fixed days; a request to Infra-Iam-PKI for a provisioner with a 7-30 d default (their W5).
- **Acceptance:** the integration test issues and renews against Pebble configured with a 24 h validity; the lab issues against the real step-ca.
- **Measure:** renewals that miss the window across 7 days of simulated 24 h certificates: unknown → 0.

### P8. Keycloak client and roles (DEC-001, FR-3 partial): **platform side done** ([KEYCLOAK_CLIENT.md](../operations/KEYCLOAK_CLIENT.md)); Infra-IAM client and the manual login test open

- **Deliverables:** an OIDC client spec (redirect URI, scopes, a `roles` claim mapper) handed to Infra-IAM; Open WebUI `ENABLE_OAUTH_ROLE_MANAGEMENT`, `OAUTH_ROLES_CLAIM`, `OAUTH_ALLOWED_ROLES`, `OAUTH_ADMIN_ROLES` (present in v0.11.4 `config.py`), so admin and access come from Keycloak groups instead of the "first login is admin" step.
- **Acceptance:** AC-3.4 signed; the policy test requires role management to be on.
- **Measure:** manual steps in RUNBOOK §3 for the first admin: 1 (SSH tunnel) → 0.

### P9. Schema-aware rollback (C6)

- **Deliverables:** before and after every deploy, record the LiteLLM Prisma migration list and the Open WebUI migration head. Rollback restores data only if a head moved; otherwise it keeps data even when the image changed.
- **Acceptance:** integration test with an image change and no migration (data kept) and with a migration (data restored).
- **Measure:** writes lost on an automatic rollback with no schema change: all since the pre-deploy backup → 0.

### P10. Off-host backup and go-live (DEC-006)

- **Deliverables:** `BACKUP_DIR` on the institutional share or an rsync timer to it; PVE `vzdump` of the VM excluding the weights disk; quarterly restore rehearsal in the RUNBOOK with its record; user-visible `CHANGELOG.md` starting at go-live.
- **Acceptance:** a restore from the off-host copy on a fresh VM passes the smoke test.
- **Measure:** restore time from off-host, measured (target set when the share's bandwidth is known).

### P11. Repository skills (C9)

- **Deliverables:** `.agents/skills/{image-upgrade,release-record,gpu-passthrough-change}/SKILL.md`, with `.claude/skills` as a symlink to them; a static check that every script, flag and file a skill names still exists.
- **Measure:** stale references in skills → 0 (mutation: rename a flag, the check fails).

## 3. Cross-repository work (not done here)

| Repo | Item | Why |
| :-- | :-- | :-- |
| AiAgentInfrastructure | ADR superseding `docs/BIOME-L40S.md`: the BIOME lane becomes a client of this platform (ADR-014): `api_base`, alias `lifewatch-chat`, virtual key, stunnel only if DEC-010 | R3-06 |
| Infra-Iam-PKI | ACME provisioner for the platform with a 7-30 d certificate lifetime; Keycloak client per P8 | R3-10, DEC-001 |

## 4. Measurement register (fill in; protocol ADR-013)

| Date | Package | Metric | Baseline | Result | Runs | Gate |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| 2026-10-12 | review | CI jobs green on `main` | — | 2/4 (unit red, integration skipped) | 1 | baseline |
| 2026-10-12 | review | images pinned by digest | — | 6/6 | static | baseline |
| 2026-10-12 | review | pins tracked by a bot | — | 0/8 | static | baseline |
| 2026-10-12 | review | policy checks with a mutation test | — | 0 | static | baseline |
| 2026-10-12 | review | 2-GPU KV left, Qwen2.5-72B FP8 (computed) | — | 6-8 GiB, 16k context | computed | baseline, to be measured (AC-3.1) |
| 2026-10-12 | review | 2-GPU KV left, Qwen3.6-35B-A3B FP8 (computed) | 6-8 GiB | ~40 GiB, 262k context | computed | candidate for P5 |
| 2026-10-12 | review | 1-GPU KV left, Qwen3-Coder-30B-A3B FP8 (computed) | — | ~9.5 GiB, ~100k tokens BF16 KV | computed | candidate for P5 |
| 2026-10-12 | P0 | CI jobs green on `main` | 2/4 | fix in working tree, CI not run yet | — | pending CI |
| 2026-10-12 | P0 | bats assertions that never executed (bare `! cmd`, R3-11) | 24 | 0; all 24 still pass; 2 mutations caught | 1 | ✔ |
| 2026-10-12 | P0 | secret globs readable by agents / mutating commands without confirmation | all / all | 0 / 0 (`tests/compose/agent-guardrails.bats`) | static | ✔ |
| 2026-10-12 | P1 | pins tracked by a bot | 0/8 | 7/8 (6 compose images + actions; Makefile and test images untracked) | static | ✔ (target ≥ 7/8) |
| 2026-10-12 | P3 | profiles with tool calling on and a known parser | 0/1 | 3/3 (policy test) | static | ✔ |
| 2026-10-12 | P3 | limit and budget enforcement tests | 0 | 2 unit (payload, validation) + integration step 3b (429, spend > 0) not yet run | — | pending CI |
| 2026-10-12 | P4 | correct profile decisions on fixtures (0, 1, 2, 3 L40S; other GPU; override; explicit file) | — | 7/7 | 1 | ✔ |
| 2026-10-12 | P4 | host passthrough: 1 or 2 GPUs, subset, owner conflict (tests) | 2-GPU only | 1, 2 or a subset; card owned by another VM refused; 2 mutations caught | 1 | ✔ |
| 2026-10-12 | P1 | services with cpu and memory limits | 0/4 | 4/4 (vLLM exempt, reason in compose.yaml) | static | ✔ |
| 2026-10-12 | P2 | policy checks with a mutation case / surviving mutations | 0 / — | 33 mutations, 33 killed; first run found 2 gaps (no test for `turn_off_message_logging`, tool smoke test accepted `tool_choice: none`), both closed | 3 | ✔ |
| 2026-10-12 | P2 | `make mutation` runtime | — | 10 s | 1 | ✔ (no guard set) |
| 2026-10-12 | P5 | harness: gate correct on synthetic pass/fail cases; golden tasks valid | — | 4/4 gate cases, 20 seed tasks (10 agent, 10 science) | 1 | ✔ (research set still missing) |
| 2026-10-12 | lab | prerequisites reported per run of the lab | first one only (stopped at `LAB_DIR`) | all 8 phases, every problem listed (this laptop: 4: toolkit, CDI, LAB_DIR, disk 19/30 GB) | 1 | ✔ |
| 2026-10-12 | all | bats tests / runtime | 135 / 51 s | 168 / 62 s | 1 | ✔ (guard: runtime ≤ +30 %: +22 %) |

## 5. Risks

| Risk | Mitigation |
| :-- | :-- |
| The best 1-GPU model is clearly worse for researchers | ADR-015 §2 keeps the second card here; the gate is pre-registered |
| Hybrid MoE models need vLLM features not exercised in the lab (linear-attention state, FP8 on Ada) | lab cannot prove it (A2000 is Ampere); P5 runs on the host with AC-3.1 per profile |
| Agents saturate the GPUs | per-key `max_parallel_requests` (P3), tuned from P5 load numbers; alerts (P6) |
| Two profiles double upgrade work | the profile table is small and validation is scripted (P5 `bench/`) |
| Cross-repo items stall | this repo's side works without them: public CA and phase 1 stay available, and agents can use the API with a key |
