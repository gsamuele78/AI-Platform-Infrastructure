# AGENTS.md: context for AI agents working on this repository

Read by opencode, OpenHands, Codex and Claude Code (through `CLAUDE.md`). Decisions live in `docs/adr/`, open questions in `docs/DECISIONS_REQUIRED.md`, ordered work in `docs/plan/PLAN.md`. This file holds only what an agent needs before touching anything.

## What this repository is

The LifeWatch ERIC / BIOME on-premise LLM service for researchers: one Ubuntu 24.04 VM on Proxmox VE 9.x with **one or two NVIDIA L40S** passed through. vLLM serves the model (alias `lifewatch-chat`). LiteLLM is the OpenAI-compatible API with per-key RBAC and limits, Open WebUI is the web chat with Keycloak OIDC, and nginx is the only public entry point (TLS). Agents on researchers' machines are ordinary API clients ([ADR-014](docs/adr/ADR-014-agent-client-contract.md)).

```text
Proxmox host ── vfio-pci ──► VM: nginx :443 (UI) / :8443 (/v1 only)
                                  ├─ Open WebUI ── Keycloak OIDC (Infra-Iam-PKI)
                                  └─ LiteLLM (virtual keys, limits) ── Postgres
                                       └─ vLLM (internal network, 1 or 2 L40S)
```

## Read before proposing changes

1. `docs/plan/PLAN.md`: what is next and how each package is measured.
2. `docs/adr/`: especially ADR-010 (release/rollback), ADR-012 (GPU profiles), ADR-013 (measure before adopting), ADR-014 (client contract).
3. `docs/audit/PRODUCTION_READINESS_AUDIT.md`: findings F-xx, R2-xx, R3-xx. Many of the traps below come from there.

## Invariants (enforced by tests; CI fails if you break them)

| # | Invariant | Enforced by |
| :-- | :-- | :-- |
| 1 | Every image pinned by `@sha256` digest, never `:latest` | `tests/compose/policy.bats` |
| 2 | Only the ingress publishes beyond loopback, and only 80/443/8443; the API port serves `/v1/*` only | `policy.bats`, `smoke-test.sh` |
| 3 | vLLM on an internal network with no egress, weights pre-staged at a pinned revision (`HF_HUB_OFFLINE=1`) | `policy.bats`, `preflight.sh` |
| 4 | No host namespaces; `cap_drop: [ALL]` on gateway, UI, DB, ingress | `policy.bats` |
| 5 | Models are defined in git only (`STORE_MODEL_IN_DB=False`); the served alias is `lifewatch-chat` in every profile | `policy.bats` |
| 6 | Tool calling on, with the parser set by the profile (ADR-014) | `policy.bats` |
| 7 | Every mutating host script plans by default and changes nothing without `--apply`; apply writes a manifest before mutating; rollback is manifest-driven and refuses on drift | `tests/pve/*.bats` |
| 8 | Deploy refuses uncommitted changes, backs up before any change, rolls back automatically on failed health or smoke test | `tests/deploy/*.bats` |
| 9 | No secrets in git: `.env` is mode 600 and never committed; `.env.example` holds `CHANGE_ME` only | `make secrets`, `preflight.sh` |
| 10 | Prompts and responses are never logged (vLLM default, LiteLLM `turn_off_message_logging`) | `policy.bats` |
| 11 | The repository is public: no internal host names, IP addresses or user names in committed files | review (PLAN P2 adds a check) |

## Commands

```bash
make lint test        # shellcheck + bats (stubbed hardware); no Docker daemon, no GPU
make integration      # real gateway/UI/DB, fake GPU backend; needs Docker
make vm-test          # disposable Ubuntu 24.04 VM (vagrant-libvirt)
sudo make lab-gpu     # real vLLM on one local NVIDIA GPU, small model (profiles/lab.env)
# GPU profile: the guest counts L40S on its PCI bus -> profiles/l40s-1.env or l40s-2.env
# (override: LW_PROFILE=l40s-1). New profiles start as PROFILE_STATUS=candidate.
# host (Proxmox) and guest (VM) procedures: docs/operations/PROXMOX_PASSTHROUGH.md, RUNBOOK.md
```

## Conventions

- One work package per PR (`docs/plan/PLAN.md`); fill its measurement row, including "target missed" or "not run".
- ADRs are not rewritten: amend them with a dated "Amendment" section or supersede them with a new one.
- Bats: never write a bare `! cmd` in the middle of a test, because bats ignores it. Use `refute cmd` (helper in `tests/helpers/common.bash`).
- Shell scripts: `set -euo pipefail`, shellcheck clean, everything overridable by environment variables so tests can fake the host.

## Known traps (each one happened)

| Trap | Symptom | Remedy |
| :-- | :-- | :-- |
| Model id taken from a blog post or an old card (F-01) | the model does not exist, deploy fails | check the Hugging Face API, pin `MODEL_REVISION` |
| Context sized without the KV budget (F-02) | vLLM refuses to start | compute it as in PRD §2; record `# GPU blocks` on the host (AC-3.1) |
| `ENABLE_OIDC_AUTH` / `OIDC_*` in Open WebUI (F-04) | SSO silently off | the variables are `OAUTH_*` and `OPENID_PROVIDER_URL` (`…/.well-known/openid-configuration`) |
| LiteLLM JWT/OIDC auth (F-06) | needs an Enterprise licence | people use OIDC at Open WebUI; API clients use virtual keys |
| NCCL P2P inside the VM (F-20) | hangs at "Initializing NCCL" | `NCCL_P2P_DISABLE=1`, `--disable-custom-all-reduce` |
| `dpkg -l \| grep -q` under `pipefail` (F-13) | false negatives (SIGPIPE) | `dpkg-query -W` |
| `apt-mark hold` on packages that are not installed (R2-05) | apt aborts | hold only what `dpkg-query` reports installed |
| Podman's Docker API ignores `driver: nvidia` (R2-07) | no GPU in the container | CDI device request (`tests/lab/compose.podman-gpu.yaml`) |
| Compose versions report different missing variables first (R3-01) | CI red on a newer runner | leave exactly one variable missing in the test |
| vLLM tool calling is off by default (R3-02) | agents get errors on `tool_choice: auto` | `--enable-auto-tool-choice --tool-call-parser <profile parser>` |
| Bare `! cmd` in a bats test | the assertion never runs | `refute cmd` |
| Integration test run as an unprivileged user | nginx crash-loops: `Permission denied` on `fullchain.pem` (ingress has `cap_drop: ALL`, no `DAC_OVERRIDE`) | run it as root, like production (`sudo make integration`; CI does) |
| Host Docker daemon on the maintainer's workstation | breaks the libvirt lab | keep it off; `docker compose config` works without the daemon |

## Out of scope here

Agent harnesses and the maintainer's personal gateway (AiAgentInfrastructure), Keycloak and step-ca (Infra-Iam-PKI), Kubernetes, multi-node HA.
