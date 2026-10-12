# Acceptance Criteria & Validation Matrix

"Automated" means a test or script exits non-zero when the criterion is not met. "Manual" items need the GPU host or the real Keycloak realm, and are signed off in the release record.

## 1. Hypervisor (Proxmox host)

| ID | Criterion | Verified by |
| :-- | :-- | :-- |
| AC-1.1 | Preflight is read-only and fails on: not PVE, IOMMU inactive, no L40S, more than 2 selected, a **selected** GPU sharing an IOMMU group with an unrelated device | `scripts/pve/preflight.sh`, `tests/pve/preflight.bats` |
| AC-1.2 | Passthrough is planned by default and changes nothing without `--apply` | `tests/pve/configure-passthrough.bats` |
| AC-1.3 | Apply refuses a running or non-q35 VM and a GPU already passed to another VM, attaches only the `--gpu` selection (default: all, max 2), backs up and writes a manifest before mutating, never overwrites existing `hostpciN` entries, and a second run is a no-op | same |
| AC-1.4 | Rollback restores the exact pre-change state, keeps unrelated VM edits, and refuses on drift | `tests/pve/rollback-passthrough.bats` |

## 2. Guest VM

| ID | Criterion | Verified by |
| :-- | :-- | :-- |
| AC-2.1 | Every L40S on the guest's PCI bus (1 or 2) is visible to the driver with ≥ 45,000 MiB, and a CUDA container can use them | `scripts/verify/vm-check.sh` (manual run on the host) |
| AC-2.2 | Bootstrap uses signed apt repositories only and holds the runtime packages | `tests/vm/vm-scripts.bats` |

## 3. Serving and gateway

| ID | Criterion | Verified by |
| :-- | :-- | :-- |
| AC-3.1 | For **each** profile in use (`l40s-1`, `l40s-2`): vLLM starts the profile's model without CUDA OOM or a KV-capacity error; the `# GPU blocks` log line and the golden-set result are recorded, and only then is `PROFILE_STATUS=validated` committed | **Manual**, on the host |
| AC-3.2 | An unauthenticated request to `/v1/chat/completions` returns 401; an invalid key returns 401 | `scripts/deploy/smoke-test.sh` (every deploy), `tests/integration/run.sh` |
| AC-3.3 | A valid key completes inference end to end | `smoke-test.sh` |
| AC-3.4 | Open WebUI login works through Keycloak; the first admin is created by the operator before the ingress opens | **Manual** (RUNBOOK §3) |
| AC-3.5 | FP8 KV cache output quality accepted on a representative prompt set | **Manual** (DEC-007) |
| AC-3.6 | Profile detection maps 1 or 2 L40S to `l40s-1`/`l40s-2`, refuses other hardware, and preflight refuses an unvalidated profile without `LW_ALLOW_UNVALIDATED=true` | `tests/vm/profile.bats` |
| AC-3.7 | Tool calling with `tool_choice: auto` is accepted and returns well-formed calls; ≥ 64k context in production profiles | `smoke-test.sh`, `tests/compose/policy.bats` |
| AC-3.8 | Per-key rpm and parallel limits return 429, and spend is counted so budgets trip | `tests/integration/run.sh` |
| AC-3.9 | Web chat roles come from Keycloak: `ai-user` → user, `ai-admin` → admin, other roles refused | `tests/compose/policy.bats` (config); **Manual** login test (KEYCLOAK_CLIENT §5) |

## 4. Release management

| ID | Criterion | Verified by |
| :-- | :-- | :-- |
| AC-4.1 | Deploy refuses uncommitted changes and failing preflight | `tests/deploy/*.bats` |
| AC-4.2 | State is backed up (verified dump plus checksums) before any change | `tests/ops/backup-restore.bats`, `tests/deploy/deploy-rollback.bats` |
| AC-4.3 | A release that fails health or smoke tests is rolled back automatically, and data is restored when stateful images changed | `tests/deploy/deploy-rollback.bats`, `tests/integration/run.sh` |
| AC-4.4 | All images are pinned by digest; only the ingress publishes beyond loopback (80/443/8443); no host namespaces | `tests/compose/policy.bats` |
| AC-4.5 | Backups land on a dedicated mount (`BACKUP_DIR`); with `BACKUP_REQUIRE_MOUNT=true` deploy refuses otherwise | `tests/deploy/preflight.bats`, `make vm-test` (separate virtual disk) |

## 5. TLS

| ID | Criterion | Verified by |
| :-- | :-- | :-- |
| AC-5.1 | HTTP redirects to HTTPS; TLS 1.2/1.3 only; the certificate verifies for PUBLIC_HOSTNAME against the active trust root | `smoke-test.sh`, `tests/compose/policy.bats` |
| AC-5.2 | The public API port serves `/v1/*` only: unauthenticated → 401, admin endpoints → 404 | `smoke-test.sh` |
| AC-5.3 | Let's Encrypt issuance and renewal via certbot webroot; a failed or wrong certificate is never installed | `tests/ops/tls.bats`, `tests/integration/run.sh` (Pebble) |
| AC-5.4 | Let's Encrypt with the real CA and public DNS | **Manual**, once DEC-002 is decided |

## 6. Lab (before real hardware)

| ID | Criterion | Verified by |
| :-- | :-- | :-- |
| AC-6.1 | The production images serve real inference on one local GPU with the lab model, through gateway and TLS ingress; deploy, backup and rollback succeed | `sudo make lab-gpu` (`docs/operations/LAB.md`) |
