# Laptop Lab: Pre-Deployment Testing

Everything that can be proven without the L40S host is proven on a developer laptop, at three levels:

| Level | What runs | Proves | Command | Needs |
| :-- | :-- | :-- | :-- | :-- |
| 1. Unit + policy | bats, stubbed hardware | script logic, Compose policy | `make lint test` | nothing |
| 2. Real OS, fake GPU | disposable Ubuntu 24.04 VM | bootstrap, deploy/rollback, backups on a mounted disk, TLS ingress, Let's Encrypt flow (against Pebble) | `make vm-test` | vagrant + vagrant-libvirt (no sudo) |
| 3. Real GPU, small model | rootless Podman + one NVIDIA GPU | the production images (vLLM v0.31) serving real inference end to end through gateway and TLS ingress | `make lab-check`, `sudo make lab-setup`, `make lab-gpu` | NVIDIA driver >= 580, nvidia-container-toolkit |

The lab profile `profiles/lab.env` changes only the model and its capacity (`Qwen/Qwen3.5-0.8B`, TP=1, 8k context). It is the smallest model with the production architecture (Qwen3.5 hybrid attention, `qwen3_coder` tool calls, `qwen3` reasoning), so the lab exercises the same vLLM code paths and parsers as Qwen3.8-27B. Images, gateway, UI, ingress, backups and scripts are identical to production, and so is the served alias `lifewatch-chat`.

## What the laptop cannot prove

- That the 72B FP8 model fits in 2 × L40S with the chosen KV budget (AC-3.1). This needs the real host.
- FP8 KV cache accuracy (DEC-007). FP8 W8A8 needs Ada (sm_89) or newer; an A2000 is Ampere (sm_86).
- Tensor parallelism and NCCL inside the Proxmox VM.
- PCIe passthrough itself (`scripts/pve/*` is covered only by the stubbed tests).
- Let's Encrypt production issuance: it needs a public DNS name and port 80 reachable from the internet.

## Level 3: setup and run

The lab runs **rootless Podman as your normal user**, with its own storage under `LAB_DIR` (default `/srv/lifewatch-lab`). Your normal Podman and the Docker daemon are not touched: the Docker daemon may stay off, and only the `docker` CLI with the compose plugin is used as a client.

```bash
make lab-check            # read-only: 8 phases, lists every problem at once, changes nothing
sudo make lab-setup       # once: installs or creates only what is missing (safe to repeat)
make lab-gpu              # WITHOUT sudo: full cycle, then tears everything down
make lab-gpu KEEP=1       # leave it running to try the UI
```

| Phase | Checked | `lab-setup` fixes it? |
| :-- | :-- | :-- |
| 1 System | `docker` CLI + compose plugin, `jq`, `curl`, `openssl`, `ss` | no (lists the `apt-get install` to run) |
| 2 GPU and driver | driver ≥ 580 (vLLM v0.31 images use CUDA 13), VRAM ≥ 4000 MiB | no: the driver is never touched |
| 3 Rootless Podman | `podman` installed, subordinate UID/GID ranges for your user | no (prints the `usermod` command) |
| 4 NVIDIA Container Toolkit | `nvidia-ctk` present | **yes**: `apt-get install nvidia-container-toolkit`, adding NVIDIA's signed repository only if no apt source offers it |
| 5 CDI spec | `/etc/cdi/nvidia.yaml` exists **and** matches the loaded driver (it goes stale after every driver update) | **yes**: `nvidia-ctk cdi generate` |
| 6 Lab directory | `LAB_DIR` exists and belongs to you | **yes**: created (or the directory itself handed to you), mode 700 |
| 7 Disk space | first run ~30 GB free on `LAB_DIR`'s filesystem (estimate: 11.4 GB of compressed images, about twice that unpacked, plus the 1.75 GB model and pull scratch space); later runs ~3 GB | no: nothing is ever deleted. It lists the roomiest filesystems, leaving out cloud-sync, backup and boot mounts |
| 8 Ports | 8081, 8444, 8445 (ingress), 4000, 8080 (operator ports) free | no |

`make lab-gpu` runs the same check as its phase 0 and stops before starting anything if a phase fails.

To put the lab on another filesystem, use the same `LAB_DIR` for all three commands, for example `LAB_DIR=/data/lab make lab-check`, then `sudo LAB_DIR=/data/lab make lab-setup`, then `LAB_DIR=/data/lab make lab-gpu`.

Do **not** run `scripts/vm/bootstrap.sh` on the laptop: it targets the Ubuntu 24.04 guest and installs a datacenter driver branch.

With `KEEP=1`, open https://localhost:8444 after importing `LAB_DIR/tls/live/ca.pem` into the browser (or accept the warning). The first account you register becomes admin; sign-up is enabled in the lab only (`WEBUI_ENABLE_SIGNUP=true`). API: `https://localhost:8445/v1` with a key from `scripts/ops/issue-key.sh`. Stop it with `docker compose -p lwlab down` (with `DOCKER_HOST` as printed), then `tests/lab/podman-service.sh stop`.

The first run downloads the images (about 11.4 GB compressed, 9 GB of it vLLM) and the model (1.75 GB) into `LAB_DIR`. Both are reused later. Image layers are staged in `LAB_DIR/tmp` while pulling, not in the RAM-backed runtime directory.

Ports used on the laptop: 8081, 8444, 8445 (ingress, loopback) and 4000, 8080 (operator ports, loopback). Rootless Podman cannot bind ports below 1024, which is why they differ from production.
