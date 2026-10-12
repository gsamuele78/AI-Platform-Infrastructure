# Operations Runbook

All commands run from the repository checkout on the indicated machine. Stack commands run as root on the guest VM (the `docker` group is root-equivalent and is not used). Every mutating script supports a plan or dry-run first; read its output before applying.

## 1. Proxmox host: GPU passthrough

```bash
bash scripts/pve/preflight.sh                              # read-only; must end with [PASS]
bash scripts/pve/configure-passthrough.sh --vm-id 100      # plan only
qm shutdown 100
bash scripts/pve/configure-passthrough.sh --vm-id 100 --apply
reboot                                                     # binds vfio-pci
bash scripts/pve/preflight.sh                              # GPUs now show "bound to vfio-pci"
qm start 100
```

Preflight failures:
- **IOMMU not active:** enable VT-d/AMD-Vi in firmware. On older kernels also add `intel_iommu=on` (GRUB: `/etc/default/grub` + `update-grub`; systemd-boot: `/etc/kernel/cmdline` + `proxmox-boot-tool refresh`).
- **GPU shares an IOMMU group:** move the card to another slot or check the ACS setting in firmware. Do **not** use the ACS-override patch in production; it removes the isolation guarantee.
- **VM warnings:** use `bios: ovmf`, `cpu: host` and `balloon: 0`. The L40S 64-bit BARs need OVMF and enough physical address bits.

Rollback:
```bash
bash scripts/rollback/rollback-passthrough.sh --list
bash scripts/rollback/rollback-passthrough.sh --backup-dir /var/backups/lifewatch-pve/<id>          # plan
qm shutdown 100 && bash scripts/rollback/rollback-passthrough.sh --backup-dir <dir> --apply && reboot
```
If it reports drift, someone changed the VM or host files after the apply. Compare against `<dir>/*.orig` and resolve by hand; the script changes nothing while drift exists.

## 2. Guest VM: bootstrap

```bash
sudo bash scripts/vm/bootstrap.sh       # driver 580-server (CUDA 13 images), Docker, NVIDIA toolkit (held)
sudo reboot
sudo bash scripts/verify/vm-check.sh    # 2 GPUs >= 45000 MiB, container access, P2P matrix
```
Leave `NCCL_P2P_DISABLE=1` and `--disable-custom-all-reduce` in `compose.yaml` unless `nvidia-smi topo -p2p r` reports `OK` between GPU0 and GPU1. Change them only through a reviewed PR, followed by a load test.

## 3. First deployment

Before you start: attach a dedicated disk for backups and mount it at `BACKUP_DIR` (default `/srv/lifewatch-backups`, see §6).

```bash
cp .env.example .env && chmod 600 .env    # fill every CHANGE_ME (openssl rand -hex 32), PUBLIC_HOSTNAME, TLS_DIR, BACKUP_DIR
sudo bash scripts/vm/fetch-model.sh       # ~75 GB at the pinned revision
sudo bash scripts/ops/tls-selfsigned.sh   # TLS phase 1 (§9)
sudo make preflight
sudo make deploy                          # warns: OPENWEBUI_API_KEY empty
KEY=$(sudo bash scripts/ops/issue-key.sh --alias open-webui)
sudo sed -i "s|^OPENWEBUI_API_KEY=.*|OPENWEBUI_API_KEY=${KEY}|" .env
sudo make deploy                          # gateway/UI only; vLLM is not restarted
sudo bash scripts/ops/install-timers.sh   # daily backup timer
```
**First admin:** the first account to log in to Open WebUI becomes admin. Before opening the firewall for 80/443/8443, the operator logs in through an SSH tunnel (`ssh -L 8080:127.0.0.1:8080 vm`) with their Keycloak account. Record the vLLM `# GPU blocks` log line in the release record (AC-3.1).

## 4. Routine deployment

1. Merge the change by PR (CI green). On the VM: `git pull --ff-only`.
2. `sudo make deploy`. It snapshots the release, backs up state, pulls images, waits for health, smoke-tests and cuts over. Any failure rolls back automatically.
3. Expected downtime: none for config-only changes, seconds for gateway/UI image changes, and **the model load time** (~5-15 min) for vLLM changes. Announce vLLM changes as maintenance.

## 5. Rollback

- **Automatic:** a failed deploy restores the previous release, and restores data only when a stateful image changed. Look for `rolled back to <id>` in the output.
- **Manual, after a deploy that passed but misbehaves:**
  ```bash
  sudo bash scripts/deploy/rollback.sh --previous
  ```
  If stateful images differ, the script stops and asks you to choose:
  - `--restore-backup <dir>`: `pre_deploy_backup` in `releases/current/meta`. Everything written since that deploy is lost.
  - `--no-restore`: keeps the data. Only safe when the newer release ran no schema migration (check the LiteLLM / Open WebUI release notes).
- **"MANUAL INTERVENTION REQUIRED":** the rollback target itself is unhealthy. Run `docker compose -p lifewatch ps` and `docker compose -p lifewatch logs --tail 200 <service>`, then follow §7.

## 6. Backup and restore

Backups go to `BACKUP_DIR` (`.env`), which should be a **dedicated mount**: today a separate virtual disk, later an NFS/CIFS export. Preflight warns when it is not a mountpoint; set `BACKUP_REQUIRE_MOUNT=true` to make that fatal. Each backup holds a verified Postgres dump, the Open WebUI volume, `TLS_DIR` (CA key, certificates, ACME account) and `SHA256SUMS`, so a copied backup can be verified anywhere with `sha256sum -c SHA256SUMS`.

```bash
# one-time: dedicated disk for backups
sudo mkfs.ext4 -L lw-backups /dev/sdX
echo 'LABEL=lw-backups /srv/lifewatch-backups ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /srv/lifewatch-backups && sudo mount /srv/lifewatch-backups && sudo chmod 700 /srv/lifewatch-backups
# later, to export: mount the institutional share at the same path (or rsync to it)

sudo make backup                                        # keeps the newest 14 in BACKUP_DIR
sudo bash scripts/ops/install-timers.sh                 # daily at 02:30 (Open WebUI pauses a few seconds)
sudo bash scripts/ops/restore.sh --from <dir>           # asks for confirmation; leaves gateway/UI stopped
sudo bash scripts/deploy/rollback.sh --to $(basename $(readlink -f /var/lib/lifewatch/releases/current)) --no-restore --yes
```
Copy backups off the VM (DEC-006); a backup on the same disk does not survive losing the VM. Rehearse a restore every quarter: an untested backup does not count as a backup.

## 7. Incidents

| Symptom | Likely cause | Action |
| :-- | :-- | :-- |
| vLLM log: `max seq len … larger than the maximum number of tokens that can be stored in KV cache` | KV budget too small | Lower `VLLM_MAX_MODEL_LEN` or `VLLM_MAX_NUM_SEQS` in `release.env` (PR, deploy) |
| vLLM `CUDA out of memory` at start | Utilisation too high for activations | Lower `VLLM_GPU_MEMORY_UTILIZATION` to 0.88 |
| vLLM hangs at "Initializing NCCL" | P2P inside the VM | Confirm `NCCL_P2P_DISABLE=1`; check `nvidia-smi topo -p2p r` |
| vLLM unhealthy, `HF_HUB_OFFLINE` / file not found | Weights not staged at the pinned revision | `scripts/vm/fetch-model.sh` |
| Gateway 401 for the UI | `OPENWEBUI_API_KEY` revoked or missing | Issue a new key (§3), deploy |
| Gateway 5xx, vLLM healthy | Backend key mismatch | `VLLM_API_KEY` must be identical for both services (one `.env`) |
| Users logged out after every deploy | `WEBUI_SECRET_KEY` changed | Keep it stable; it is required by preflight |

## 8. Upgrading pinned images (DEC-005)

1. Read the upstream release notes between the pinned and the target versions, in particular removed or renamed CLI flags (vLLM) and migrations (LiteLLM, Open WebUI).
2. Resolve the digest: `docker buildx imagetools inspect <image>:<tag> --format '{{json .Manifest.Digest}}'`.
3. Change **one** component per PR, with its digest. CI runs the policy and integration tests.
4. Run `make vm-test` and `sudo make lab-gpu` on a laptop first: they catch removed flags, migrations that fail on a fresh database, and container hardening that breaks the new image.
5. Deploy in a maintenance window (stateful images change, so the pre-deploy backup is the rollback path), record AC-3.1, and run the representative prompt set (DEC-007).

Upgrade notes from the 2026-10 jump (vLLM 0.6.3 → 0.31.0, LiteLLM 1.52 → 1.104.2, Open WebUI 0.3.30 → 0.11.4):
- vLLM images are built on CUDA 13.0, so the driver must be >= 580; the entrypoint is `vllm serve`; `--disable-log-requests` was removed (prompts are not logged by default); weights are downloaded with `hf` (huggingface_hub 1.x), not `huggingface-cli`.
- The LiteLLM image tags are `vX.Y.Z` (no more `main-` prefix).

## 9. TLS certificates

| Phase | Command | Trust |
| :-- | :-- | :-- |
| 1. Self-signed lab CA | `sudo bash scripts/ops/tls-selfsigned.sh` | clients import `TLS_DIR/live/ca.pem` once; re-running renews the server cert and keeps the CA |
| 2. Let's Encrypt | `sudo bash scripts/ops/tls-letsencrypt.sh --email ops@lifewatch.eu --staging`, check, then the same without `--staging`; then `sudo bash scripts/ops/install-timers.sh --with-cert-renew` | public |
| Institutional CA | put `fullchain.pem` and `privkey.pem` into `TLS_DIR/live/`, `echo institutional > TLS_DIR/live/mode`, then `docker exec $(docker ps -qf label=com.docker.compose.service=ingress) nginx -s reload` | public/internal |

Let's Encrypt prerequisites: `PUBLIC_HOSTNAME` resolves publicly to this host, and port 80 is reachable from the internet (HTTP-01). Use `--staging` first, because production has strict rate limits. An internal-only host cannot use HTTP-01: use the institutional CA, or a certbot DNS-01 plugin if the DNS provider has an API.

Failure behaviour: if certbot fails, or the new certificate does not cover the hostname or match its key, the served certificate is untouched. nginx is reloaded only after `nginx -t` passes. Preflight fails on an expired certificate and warns 14 days before expiry.
