# Production Readiness Audit

**Date:** 2026-10-09 · **Scope:** whole repository · **Method:** read every file, check every external claim against its source (Hugging Face API, upstream docs and source at the pinned versions, registry digests), then fix test-first.

**Assumptions are pessimistic on purpose:** a claim counts as true only if a tool returned evidence for it, and anything that cannot be exercised without the real hardware is listed as unverified. It is not treated as working.

## Verdict

**Not ready for production.** After the fixes below the repository is a sound, tested base, but these go-live blockers remain open (see [DECISIONS_REQUIRED.md](../DECISIONS_REQUIRED.md)):

| Blocker | Why it blocks | Decision |
| :-- | :-- | :-- |
| 72B on the L40S host not yet run | KV-cache headroom, FP8 W8A8 and FP8 KV accuracy, TP=2 and NCCL inside the VM can only be measured there. The upgraded images are validated on a VM (fake GPU) and a laptop GPU (small model). | AC-3.1, DEC-005, DEC-007 |
| Public trust for TLS | TLS works with the self-signed lab CA; Let's Encrypt is implemented but needs the public name and port 80 reachable. | DEC-002 |
| Backups not yet off-host | They now go to a dedicated mount; it still has to become (or sync to) an external share. | DEC-006 |

## Round 3 (2026-10-12): cross-repo and hybrid-agent review

Compared with AiAgentInfrastructure, Infra-Iam-PKI and the OpenHands repositories. The analysis is in [PRACTICES_EVALUATION.md](../plan/PRACTICES_EVALUATION.md) and the work in [PLAN.md](../plan/PLAN.md). The topology changed: this platform gets one **or** two L40S, with the profile chosen by hardware detection ([ADR-012](../adr/ADR-012-gpu-profiles-from-hardware-detection.md)), and the second card goes to TensorFlow compute only if a benchmark justifies it ([ADR-015](../adr/ADR-015-second-gpu-allocation-by-benchmark.md)). It must also serve agents ([ADR-014](../adr/ADR-014-agent-client-contract.md)). Code changes followed the same day (see the Resolution column).

| ID | Sev. | Finding | Evidence | Resolution |
| :-- | :-- | :-- | :-- | :-- |
| R3-01 | HIGH | CI on `main` is red: a policy test depends on which missing variable the Compose version reports first. The claim below that CI runs on every push was true; the claim that it passes no longer is. | Actions run 2026-10-12, `not ok 2 compose fails fast when a required secret is missing` | **Fixed** (test leaves exactly one variable missing) |
| R3-02 | HIGH | Tool calling is off (`enable_auto_tool_choice` defaults to False in vLLM v0.31.0), so agents cannot use the platform | vLLM `entrypoints/launchers/cli_args.py` at `v0.31.0` | **Fixed**: `--enable-auto-tool-choice` + parser per profile; smoke test checks `tool_choice: auto` |
| R3-03 | MEDIUM | Key budgets are probably always 0 for the self-hosted model (no price set), and keys have no rpm/tpm/parallel limits | `configs/proxy/config.yaml`, `issue-key.sh` | **Fixed** in config (`input/output_cost_per_token`, `issue-key.sh --rpm/--tpm/--max-parallel`); integration step 3b asserts 429 and spend > 0 (runs in CI) |
| R3-04 | MEDIUM | 16k context is below what coding agents send (OpenHands: ≥ 22k, 32k recommended) | docs.openhands.dev local-llms | **Fixed** in the profiles: 64k (1 GPU) / 128k (2 GPU) with Qwen3.8-27B; pending P5 validation |
| R3-05 | HIGH | "Exactly 2 GPUs" is hard-coded in host preflight, `vm-check.sh`, AC-1.1/2.1; passthrough cannot assign a subset | `scripts/lib/pve.sh`, `vm-check.sh` | **Fixed**: ADR-012 profiles, `--gpu` selection, count-agnostic checks |
| R3-06 | MEDIUM | AiAgentInfrastructure's BIOME lane and this platform describe incompatible servers (model name, context, auth, GPUs) | `AiAgentInfrastructure/docs/BIOME-L40S.md` | ADR-014, cross-repo item |
| R3-07 | LOW | `__pycache__/*.pyc` and `.omo/` session state are tracked in a public repo. F-25 says the obsolete generators are not in git: **they are tracked** (and so is the empty `docs/Report`) | `git ls-files` | **Fixed**: untracked, generators and `docs/Report` removed |
| R3-08 | MEDIUM | No `AGENTS.md`, no `.claude/settings.json`: agent sessions can read `.env`, TLS keys, backups and the Vagrant private key | repository tree | **Fixed**: `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json` (tested) |
| R3-09 | MEDIUM | No dependency bot and no CVE scan for digest-pinned images | no `dependabot.yml`, no Trivy | PLAN P1 |
| R3-10 | MEDIUM | With Infra-Iam-PKI's step-ca (24 h leaf default), renewal twice a day and fixed-day expiry thresholds leave one missed run before expiry | Infra-Iam-PKI CONTINUATION-PLAN W5; `install-timers.sh` | PLAN P7 |
| R3-11 | MEDIUM | 24 bats assertions written as a bare `! cmd` never ran (bats ignores a negated command that is not a test's last line), e.g. "dry-run makes no `qm set` call" | bats semantics; IDE diagnostic | **Fixed**: `refute` helper; all 24 now enforced and still pass; mutation-checked |

## Round 2 (2026-10-09): upgrade, TLS, backup mount, laptop lab

| ID | Change | Evidence |
| :-- | :-- | :-- |
| R2-01 | **Upgraded** vLLM v0.6.3 → v0.31.0, LiteLLM v1.52.0 → v1.104.2, Open WebUI v0.3.30 → v0.11.4 (digest-pinned). Breaking changes handled: vLLM removed `--disable-log-requests` (it would have crashed on start; prompts are no longer logged by default), images need CUDA 13 → driver ≥ 580 (bootstrap default 580-server, vm-check uses a CUDA 13 image), `huggingface-cli` → `hf`, LiteLLM tags lost the `main-` prefix. | vLLM source at tag v0.31.0 (`arg_utils.py`, `serve.py`, Dockerfile `CUDA_VERSION=13.0.3`); registry image configs |
| R2-02 | **TLS ingress** (nginx 1.30): phase 1 self-signed lab CA, phase 2 Let's Encrypt via certbot webroot with a renewal timer (ADR-011). Only `/v1/*` of the gateway is public; admin API stays on loopback. | `tests/ops/tls.bats`; integration step 6 runs a real ACME HTTP-01 flow against Pebble |
| R2-03 | **Backups on a dedicated mount** (`BACKUP_DIR`), daily timer plus pre-deploy, TLS material included, retention 14, `BACKUP_REQUIRE_MOUNT` gate. | `tests/deploy/preflight.bats`, VM test with a separate virtual disk |
| R2-04 | **Lab profile** `release.lab.env` (Qwen2.5-0.5B, 1 GPU) so the production images can serve real inference on a 4 GB laptop GPU. Model name is now a stable alias `lifewatch-chat` in all profiles. | `make lab-gpu` |
| R2-05 | Found by the real-OS VM test: bootstrap passed *uninstalled* driver package names to `apt-mark hold`, which aborts. | VM log: `Can't select installed nor candidate version from package 'nvidia-kernel-common-580-server-…'`; fixed, regression test added |
| R2-06 | Found by the VM test: a transient registry timeout on a multi-GB layer failed the deploy (correctly, nothing changed). Pull now retries with backoff. | VM log `net/http: timeout awaiting response headers`; regression test added |
| R2-07 | Podman's Docker-compatible API (5.4) ignores `driver: nvidia` GPU requests and honours only CDI. The lab uses a CDI override; production on Docker is unchanged. nginx no longer hard-codes Docker's DNS `127.0.0.11` (it reads the engine's resolver). | podman v5.4.2 `containers_create.go` |

## Findings

Severity: **BLOCKER** = the stack could not have worked or was unsafe as written; **HIGH** = a likely production incident; **MEDIUM** = operability or defence in depth; **LOW** = hygiene.

| ID | Sev. | Finding | Evidence | Resolution |
| :-- | :-- | :-- | :-- | :-- |
| F-01 | BLOCKER | Model `Qwen/Qwen2.5-72B-Instruct-FP8` does not exist, so vLLM could never start. | HF API returns "repository not found" for it. `RedHatAI/Qwen2.5-72B-Instruct-FP8-dynamic` exists (rev `4d9910ef…`, 75.2 GB of safetensors). | Fixed: `release.env` pins the real repo and revision. |
| F-02 | BLOCKER | `--max-model-len 32768` with a BF16 KV cache does not fit, so vLLM refuses to start. | PRD §2: about 6-8 GiB is left for KV, and one 32k sequence needs 10 GiB. | Fixed: FP8 KV cache plus a 16k context. Must still be confirmed on hardware (AC-3.1). |
| F-03 | BLOCKER | vLLM sat on an `internal: true` network (no egress) with no pre-staged weights, and `start_period: 180s` was given to a 75 GB load. It would never become healthy. | compose.yaml (original) | Fixed: `scripts/vm/fetch-model.sh`, `HF_HUB_OFFLINE=1`, preflight check of the snapshot, `start_period: 1200s`. |
| F-04 | BLOCKER | Open WebUI SSO was silently off: `ENABLE_OIDC_AUTH` and `OIDC_*` are not Open WebUI variables, and the provider URL was not the discovery document. | Open WebUI Keycloak docs: `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OPENID_PROVIDER_URL=…/.well-known/openid-configuration`. | Fixed, and enforced by a policy test. |
| F-05 | BLOCKER | The UI was published on `0.0.0.0:8080` over plain HTTP. The NGINX in the docs does not exist, and the first account to register becomes admin. | compose.yaml (original) | Fixed: loopback bind, `ENABLE_SIGNUP=false`, `DEFAULT_USER_ROLE=pending`. Ingress remains open (DEC-002). |
| F-06 | BLOCKER | ADR-004/FR-2/FR-3 (gateway validates Keycloak JWT, RBAC by group) cannot be delivered: LiteLLM JWT auth requires an Enterprise licence. | docs.litellm.ai/docs/proxy/token_auth: "JWT-based Auth requires LiteLLM Enterprise license". | Redesigned: OIDC at Open WebUI for people, scoped OSS virtual keys for API clients. ADR-004 amended, DEC-004 open. |
| F-07 | HIGH | Open WebUI held the LiteLLM **master** key, so a UI compromise meant gateway admin. | compose.yaml (original) | Fixed: `scripts/ops/issue-key.sh`; preflight refuses the master key. |
| F-08 | HIGH | `configure-passthrough.sh`: silent exit 1 when no GPU matched (`grep` under `pipefail`); matching by marketing name; no root check; no IOMMU-group isolation check; overwrote existing `hostpci0/1`; no q35 check; never bound vfio-pci or rebuilt the initramfs; applied to a running VM. | Script (original), tests in `tests/pve/` | Rewritten: PCI-ID match, isolation check, free-slot allocation, idempotent, backup and manifest written before any mutation, atomic file writes. |
| F-09 | HIGH | `rollback-passthrough.sh` restored the *latest* backup (after two applies that is not the original state), copied whole files back (clobbering unrelated VM edits), and had no drift detection. | Script (original) | Rewritten: explicit `--backup-dir`, manifest-driven surgical undo, every check runs before any mutation. |
| F-10 | HIGH | No stack deploy, rollback or backup existed, although ADR-007/009 claimed them. LiteLLM (Prisma) and Open WebUI (Alembic) migrate their schemas forward, so rolling back images without the matching data is unsafe. | Repository contents | Added `scripts/deploy/*`, `scripts/ops/*` and ADR-010. |
| F-11 | HIGH | Images were pinned by mutable tag, and CI used `ludeeus/action-shellcheck@master`. | compose.yaml, ci.yml (original) | Fixed: images by `@sha256` digest, actions by commit SHA, no third-party actions. |
| F-12 | HIGH | vLLM 0.6.x logs every prompt at INFO, putting research data in container logs. | vLLM v0.6.3 `--disable-log-requests` flag | Fixed: flag set; LiteLLM `turn_off_message_logging`. |
| F-13 | HIGH | Guest bootstrap piped `get.docker.com` into a shell, **never installed the NVIDIA driver** (so `vm-check.sh` could not pass), used `dpkg -l \| grep -q` (SIGPIPE false negatives under pipefail), added the user to `docker` (root-equivalent), and restarted dockerd unconditionally. | Script (original) | Rewritten: signed apt repos, `ubuntu-drivers --gpgpu` with precompiled modules, packages held, dockerd restarted only when its config changes. |
| F-14 | HIGH | Unattended upgrades of docker/containerd restart every container, which means an unplanned 10+ minute vLLM reload. | Operational | Runtime packages `apt-mark hold`. |
| F-15 | MEDIUM | `ipc: host` shared the host IPC namespace. | compose.yaml | `shm_size: 16gb`; a policy test forbids host namespaces. |
| F-16 | MEDIUM | No log rotation, `NCCL_DEBUG=INFO`, no healthcheck on the gateway or UI. The gateway depended on vLLM health, so it stayed down for the whole model load. | compose.yaml | Bounded json-file logs, healthchecks on every service, gateway decoupled from vLLM. |
| F-17 | MEDIUM | `usage-based-routing-v2` needs Redis (none deployed). `STORE_MODEL_IN_DB=True` lets the admin UI add models nobody reviewed. | config.yaml, compose.yaml | `simple-shuffle`, `STORE_MODEL_IN_DB=False` (GitOps). |
| F-18 | MEDIUM | `.env.example` shipped realistic-looking secrets and nothing validated them. A password with `@`, `/` or `:` breaks `DATABASE_URL`. | .env.example | `CHANGE_ME` placeholders; `scripts/deploy/preflight.sh` validates presence, strength, URL-safety and file mode 600. |
| F-19 | MEDIUM | `WEBUI_SECRET_KEY` was unset. Open WebUI then generates one outside its data volume, so every container recreate logs everyone out. | Open WebUI start.sh behaviour | Required variable. |
| F-20 | MEDIUM | Inside a VM, passthrough GPUs usually cannot do PCIe P2P, and NCCL P2P attempts can hang. | L40S has no NVLink; virtual root complex | `NCCL_P2P_DISABLE=1`, `--disable-custom-all-reduce`; `vm-check.sh` prints the P2P matrix so these can be re-enabled once validated. |
| F-21 | MEDIUM | `vm-check.sh` only warned when fewer than 2 GPUs were visible and never checked VRAM. Host preflight inferred the IOMMU from the kernel cmdline (wrong on kernel ≥ 6.8, where Intel's IOMMU is on by default) and masked `readlink` failures. | Scripts (original) | Hard failures; IOMMU detected from `/sys/kernel/iommu_groups`. |
| F-22 | MEDIUM | The only test grepped for the string `model_list`. | tests/ (original) | 99 bats tests (behavioural tests with stubbed hardware, plus policy-as-code on the rendered Compose model) and an integration lifecycle test on real containers. |
| F-23 | MEDIUM | The PRD KV formula used attention heads (64) instead of KV heads (8, GQA), overstating the KV cache 8×. | Model `config.json` | PRD §2 corrected and recomputed. |
| F-24 | LOW | The Mermaid topology did not parse (parentheses in unquoted subgraph titles) and showed components that do not exist. | diagram | Fixed. |
| F-25 | LOW | `bootstrap_repo.sh` and `build_lifewatch_platform.sh` regenerate the old files from heredocs. Running either one **reverts every fix in this audit.** | Both scripts | **Delete them.** They were left untouched because deleting them is the owner's call. (Correction 2026-10-12: they *are* tracked in git, R3-07; removal planned in PLAN P0.) |
| F-26 | LOW | Obsolete `version:` key, fixed `container_name`s (block label-based operations), empty `docs/Report`. | compose.yaml, docs/ | First two fixed; `docs/Report` left for the owner. |

## What is verified, and how

| Claim | Evidence |
| :-- | :-- |
| Passthrough plan/apply/idempotency/rollback logic | `tests/pve/*.bats` against a fake sysfs, `qm` and `lspci` |
| Deploy, auto-rollback, data-restore decision, backup/restore ordering | `tests/deploy/*.bats`, `tests/ops/*.bats` (stubbed daemon; `compose config` uses the real client) |
| Compose security and consistency policies | `tests/compose/policy.bats` on `docker compose config --format json` |
| Real gateway enforces 401, scoped key issuance, backup, auto-rollback of a broken release, manual rollback, with gateway/UI/DB running under `cap_drop: [ALL]` | `tests/integration/run.sh`: **passed** 2026-10-09 in a disposable Ubuntu 24.04 VM (`make vm-test`); runs again in the CI job `integration` on every push |
| `bootstrap.sh` works on a real Ubuntu 24.04 and is idempotent (second run does not restart dockerd) | `make vm-test`: **passed** 2026-10-09 (no GPU in the VM, so the driver is installed but not exercised) |
| Pinned flags exist in vLLM v0.6.3 | upstream source at tag `v0.6.3` (`--revision`, `--kv-cache-dtype fp8`, `--disable-log-requests`, `--disable-custom-all-reduce`, `VLLM_API_KEY`) |

## What is NOT verified (no GPU host available)

- vLLM start-up with the chosen KV budget, FP8 KV accuracy, NCCL inside the VM, and whether vLLM tolerates hardening beyond `no-new-privileges` (it keeps default capabilities on purpose).
- Keycloak login end to end (needs the real realm and client).

## Residual architectural risks (accepted, documented)

- **Single node, single GPU pair:** no HA. Any vLLM change costs downtime equal to the model load time; blue/green would need double the VRAM (ADR-010).
- **Postgres major-version upgrades** are outside automatic rollback (the data directory format changes). Do them as a planned migration.
- **Kernel command line** is not managed by the scripts (it depends on the bootloader). Preflight fails if the IOMMU is off.
- **Observability (ADR-008) and LoRA governance (ADR-005)** are designed but not implemented.
