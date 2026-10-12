# Technical Architecture Document

## System layers and boundaries

1. **Hypervisor (Proxmox VE 9.x):** owns the hardware, binds both L40S to `vfio-pci`, and manages the VM lifecycle. Changes go through `scripts/pve/*` (plan, apply, manifest rollback; ADR-002, ADR-009).
2. **Guest VM (Ubuntu 24.04 LTS):** NVIDIA datacenter driver (precompiled signed modules), Docker Engine and NVIDIA Container Toolkit from signed repositories, runtime packages held (ADR-001).
3. **Ingress (nginx, ADR-011):** the only published service. TLS 1.2/1.3; Open WebUI on 443, the API (`/v1/*` only) on 8443, ACME challenges and an HTTPS redirect on 80. Certificates: self-signed lab CA first, then Let's Encrypt.
4. **Presentation (Open WebUI):** people authenticate here with Keycloak OIDC. It calls the gateway with a scoped virtual key, never the master key (ADR-004).
5. **Gateway (LiteLLM + Postgres):** the only path to the model. Virtual keys, per-key model allow-lists, budgets and spend audit. Models are defined in git only (`STORE_MODEL_IN_DB=False`).
6. **Inference (vLLM):** on an internal Docker network with no egress and no published port, running offline from pinned, pre-staged weights, with a shared key between gateway and backend.

## Trust boundaries

| Boundary | Control |
| :-- | :-- |
| Internet → VM | nginx ingress with TLS (80/443/8443); all other services bind to `127.0.0.1`; gateway admin API not routed |
| User → UI | Keycloak OIDC; local sign-up disabled; new accounts start as `pending` |
| Client → gateway | LiteLLM virtual key (401 otherwise, checked on every deploy) |
| Gateway → vLLM | `backend-net` (internal) plus `VLLM_API_KEY` |
| Container → host | `no-new-privileges` on every service; `cap_drop: [ALL]` on gateway, UI and DB; no host namespaces (policy-tested) |

## State

| Data | Location | Protection |
| :-- | :-- | :-- |
| Gateway keys, budgets, spend logs | `postgres_data` volume | `scripts/ops/backup.sh` daily and before every deploy (pg_dump, verified) into `BACKUP_DIR` |
| UI users, chats, uploads | `openwebui_data` volume | same (copied with the UI stopped, for SQLite consistency) |
| TLS CA key, certificates, ACME account | `TLS_DIR` | archived in every backup (`tls.tgz`) |
| Model weights | `/data/vllm_cache` (NVMe) | not backed up; re-downloadable at the pinned revision |
| Release history | `/var/lib/lifewatch/releases` | immutable snapshots (ADR-010) |

Backups must also be copied off the VM (DEC-006).

## Availability, stated honestly

Single node, single GPU pair: there is no redundancy. Restarting vLLM takes minutes (weights load plus CUDA graph capture). Deploys that only touch the gateway or UI do not restart vLLM, because Compose recreates only the services that changed.
