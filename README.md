# LifeWatch ERIC Local AI Platform

Infrastructure, automation and deployment configuration for serving a local LLM on Proxmox VE with 1 or 2 NVIDIA L40S (48 GB each) passed through to one Ubuntu 24.04 VM (profile chosen by hardware detection, [ADR-012](docs/adr/ADR-012-gpu-profiles-from-hardware-detection.md)).

> **Status: not production-ready.** Remaining go-live items: validation on the L40S host (AC-3.1, DEC-007), the public DNS name and CA (DEC-002), and an off-host copy of the backup mount (DEC-006). Ordered work: [PLAN](docs/plan/PLAN.md) (1 or 2 L40S chosen by hardware detection, agent clients, model chosen by measurement). See the [production readiness audit](docs/audit/PRODUCTION_READINESS_AUDIT.md) and the [laptop lab](docs/operations/LAB.md) for what can be tested before then.

## Stack

| Layer | Component |
| :-- | :-- |
| Hypervisor | Proxmox VE 9.x, `vfio-pci` passthrough ([ADR-002](docs/adr/ADR-002-gpu-passthrough-vfio.md), [ADR-009](docs/adr/ADR-009-disaster-recovery-and-rollback.md)) |
| Guest | Ubuntu 24.04 LTS, NVIDIA 570-server driver, Docker + NVIDIA Container Toolkit |
| Inference | vLLM v0.31.0, profile chosen by GPU count ([ADR-012](docs/adr/ADR-012-gpu-profiles-from-hardware-detection.md)): `Qwen3.8-27B` FP8 with 64k context on one L40S, TP=2 with 128k on two; tool calling on ([ADR-014](docs/adr/ADR-014-agent-client-contract.md)); model choice pending measurement ([MODEL_SELECTION](docs/plan/MODEL_SELECTION.md)); lab profile: Qwen3.5-0.8B on one small GPU |
| Gateway | LiteLLM v1.104.2 (OSS) + Postgres: virtual keys with model allow-lists, rpm/tpm/parallel limits and token budgets, audit ([ADR-004](docs/adr/ADR-004-identity-and-rbac-gateway.md)) |
| UI | Open WebUI v0.11.4 with Keycloak OIDC; roles and groups from Keycloak ([KEYCLOAK_CLIENT](docs/operations/KEYCLOAK_CLIENT.md)) |
| Ingress | nginx 1.30: TLS 1.2/1.3, UI on 443, API `/v1` on 8443; self-signed lab CA, then Let's Encrypt via certbot ([ADR-011](docs/adr/ADR-011-tls-ingress.md)) |
| Backups | daily + pre-deploy to `BACKUP_DIR`, a dedicated mount ([RUNBOOK §6](docs/operations/RUNBOOK.md)) |

## Layout

```
compose.yaml           stack definition (images pinned by digest)
profiles/              GPU profiles (ADR-012): l40s-1, l40s-2 (Qwen3.8-27B FP8), lab (small model);
                       the guest picks one by counting L40S on its PCI bus
.env.example           secret template -> .env (mode 600, never committed)
configs/proxy/         LiteLLM config (models defined in git only)
configs/ingress/       nginx TLS ingress template
scripts/pve/           Proxmox host: preflight, configure passthrough
scripts/rollback/      Proxmox host: manifest-based passthrough rollback
scripts/vm/            guest: bootstrap, fetch model weights
scripts/verify/        guest: GPU acceptance check
scripts/deploy/        preflight, deploy, rollback, smoke test
scripts/ops/           backup, restore, scoped API keys, TLS (self-signed, Let's Encrypt), timers
tests/                 bats unit/policy tests + integration lifecycle
docs/                  audit, PRD, acceptance criteria, ADRs, runbook
```

## Usage

```bash
make help          # all targets
make lint test     # shellcheck + bats unit/policy tests; no Docker daemon or GPU needed
make integration   # real gateway/UI/DB with a fake GPU backend; needs Docker
make vm-test       # same, plus bootstrap.sh and a mounted backup disk, in a disposable Ubuntu 24.04 VM
make lab-check     # laptop lab prerequisites (sudo make lab-setup fixes them)
make lab-gpu       # real vLLM inference on one local NVIDIA GPU with the lab model (no sudo)
sudo make deploy   # on the guest VM: see docs/operations/RUNBOOK.md
```

Proxmox VE 9.2 GPU passthrough (1 or 2 L40S): [PROXMOX_PASSTHROUGH](docs/operations/PROXMOX_PASSTHROUGH.md). Deployment order, rollback and incident procedures: [RUNBOOK](docs/operations/RUNBOOK.md). Release mechanics: [ADR-010](docs/adr/ADR-010-release-and-rollback-strategy.md).

AI agents working on this repository: start with [AGENTS.md](AGENTS.md).
