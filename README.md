# LifeWatch ERIC Local AI Platform

Infrastructure, automation and deployment configuration for serving a local LLM on Proxmox VE with 2× NVIDIA L40S (2 × 48 GB) passed through to one Ubuntu 24.04 VM.

> **Status: not production-ready.** Remaining go-live items: validation on the L40S host (AC-3.1, DEC-007), the public DNS name and CA (DEC-002), and an off-host copy of the backup mount (DEC-006). See the [production readiness audit](docs/audit/PRODUCTION_READINESS_AUDIT.md) and the [laptop lab](docs/operations/LAB.md) for what can be tested before then.

## Stack

| Layer | Component |
| :-- | :-- |
| Hypervisor | Proxmox VE 9.x, `vfio-pci` passthrough ([ADR-002](docs/adr/ADR-002-gpu-passthrough-vfio.md), [ADR-009](docs/adr/ADR-009-disaster-recovery-and-rollback.md)) |
| Guest | Ubuntu 24.04 LTS, NVIDIA 570-server driver, Docker + NVIDIA Container Toolkit |
| Inference | vLLM v0.31.0, `Qwen2.5-72B-Instruct` FP8 W8A8, TP=2, FP8 KV cache, 16k context ([PRD §2](docs/requirements/PRD.md)); lab profile: Qwen2.5-0.5B on one small GPU |
| Gateway | LiteLLM v1.104.2 (OSS) + Postgres: virtual keys, budgets, audit ([ADR-004](docs/adr/ADR-004-identity-and-rbac-gateway.md)) |
| UI | Open WebUI v0.11.4 with Keycloak OIDC |
| Ingress | nginx 1.30: TLS 1.2/1.3, UI on 443, API `/v1` on 8443; self-signed lab CA, then Let's Encrypt via certbot ([ADR-011](docs/adr/ADR-011-tls-ingress.md)) |
| Backups | daily + pre-deploy to `BACKUP_DIR`, a dedicated mount ([RUNBOOK §6](docs/operations/RUNBOOK.md)) |

## Layout

```
compose.yaml           stack definition (images pinned by digest)
release.env            production profile: model id + revision, capacity (2 x L40S)
release.lab.env        lab profile: small model on one laptop GPU
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
sudo make lab-gpu  # real vLLM inference on one local NVIDIA GPU with the lab model
sudo make deploy   # on the guest VM: see docs/operations/RUNBOOK.md
```

Deployment order, rollback and incident procedures: [RUNBOOK](docs/operations/RUNBOOK.md). Release mechanics: [ADR-010](docs/adr/ADR-010-release-and-rollback-strategy.md).

`bootstrap_repo.sh` and `build_lifewatch_platform.sh` are obsolete generators: running either one overwrites this repository with the pre-audit files. Do not run them.
