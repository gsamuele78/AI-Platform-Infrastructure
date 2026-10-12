# Open Decision Register

| ID | Decision | Working assumption | Owner | Go-live blocker | Status |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `DEC-001` | Production Keycloak OIDC client for Open WebUI | Confidential client, redirect URI `${WEBUI_URL}/oauth/oidc/callback` | LifeWatch IT Security | Yes | **OPEN** |
| `DEC-002` | Public DNS name and certificate authority | nginx ingress implemented (ADR-011). Phase 1 self-signed lab CA is in use; Let's Encrypt (certbot HTTP-01) is implemented and tested against Pebble. Still to decide: the public name, and whether port 80 is reachable from the internet (if not: institutional CA or DNS-01). | University sysadmins | Yes, for public trust | **PARTIAL** |
| `DEC-003` | Model weight storage | Dedicated 2 TB NVMe at `/data/vllm_cache`, excluded from backups | Research group director | No | **ACCEPTED** |
| `DEC-004` | Identity at the gateway | OSS: OIDC at Open WebUI, scoped virtual keys for API clients. Alternative: buy LiteLLM Enterprise for JWT/OIDC and group-to-role mapping at the gateway (original FR-2/FR-3). | IT Security + budget holder | No (the OSS model is safe), but FR-3 stays partial | **OPEN** |
| `DEC-005` | Upgrade vLLM / LiteLLM / Open WebUI to current releases | Done 2026-10-09: vLLM v0.31.0, LiteLLM v1.104.2, Open WebUI v0.11.4 (plus nginx 1.30, certbot 5.8, driver branch 580). Validated in the VM (fake GPU) and the laptop lab (real GPU, small model). Still to do: AC-3.1 on the L40S host. | Platform team | Yes, until AC-3.1 | **IMPLEMENTED, prod validation pending** |
| `DEC-006` | Off-host backup target | Backups now go to `BACKUP_DIR`, a dedicated mount (own virtual disk), daily via `lifewatch-backup.timer` and before every deploy. Next step: make that mount an institutional NFS/CIFS share or sync it there, plus a PVE `vzdump` of the VM (excluding the weights disk). | Platform team | Yes, until off-host | **PARTIAL** |
| `DEC-007` | FP8 KV cache accuracy | Accept after an evaluation on representative prompts; otherwise use BF16 KV with `max-model-len ≤ 16384` and accept lower concurrency | Research lead | Yes | **OPEN** |
