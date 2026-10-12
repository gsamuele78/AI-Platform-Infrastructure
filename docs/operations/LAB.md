# Laptop Lab: Pre-Deployment Testing

Everything that can be proven without the L40S host is proven on a developer laptop, at three levels:

| Level | What runs | Proves | Command | Needs |
| :-- | :-- | :-- | :-- | :-- |
| 1. Unit + policy | bats, stubbed hardware | script logic, Compose policy | `make lint test` | nothing |
| 2. Real OS, fake GPU | disposable Ubuntu 24.04 VM | bootstrap, deploy/rollback, backups on a mounted disk, TLS ingress, Let's Encrypt flow (against Pebble) | `make vm-test` | vagrant + vagrant-libvirt (no sudo) |
| 3. Real GPU, small model | host Docker + one NVIDIA GPU | the production images (vLLM v0.31) serving real inference end to end through gateway and TLS ingress | `sudo make lab-gpu` | NVIDIA driver >= 580, nvidia-container-toolkit |

The lab profile `profiles/lab.env` changes only the model and its capacity (`Qwen/Qwen3.5-0.8B`, TP=1, 8k context). It is the smallest model with the production architecture (Qwen3.5 hybrid attention, `qwen3_coder` tool calls, `qwen3` reasoning), so the lab exercises the same vLLM code paths and parsers as Qwen3.8-27B. Images, gateway, UI, ingress, backups and scripts are identical to production, and so is the served alias `lifewatch-chat`.

## What the laptop cannot prove

- That the 72B FP8 model fits in 2 × L40S with the chosen KV budget (AC-3.1). This needs the real host.
- FP8 KV cache accuracy (DEC-007). FP8 W8A8 needs Ada (sm_89) or newer; an A2000 is Ampere (sm_86).
- Tensor parallelism and NCCL inside the Proxmox VM.
- PCIe passthrough itself (`scripts/pve/*` is covered only by the stubbed tests).
- Let's Encrypt production issuance: it needs a public DNS name and port 80 reachable from the internet.

## Level 3 setup (Debian 13 / Ubuntu laptop)

The driver must be >= 580 (vLLM v0.31 images are built on CUDA 13.0). Check with `nvidia-smi`.

```bash
# NVIDIA Container Toolkit (signed repo)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
  sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' |
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Do **not** run `scripts/vm/bootstrap.sh` on the laptop: it targets the Ubuntu 24.04 guest and installs a datacenter driver branch.

Run:

```bash
sudo make lab-gpu            # full cycle, then tears everything down
sudo make lab-gpu KEEP=1     # leave it running to try the UI
```

With `KEEP=1`, open https://localhost after importing `/srv/lifewatch-lab/tls/live/ca.pem` into the browser (or accept the warning). The first account you register becomes admin; sign-up is enabled in the lab only (`WEBUI_ENABLE_SIGNUP=true`). API: `https://localhost:8443/v1` with a key from `scripts/ops/issue-key.sh`.

First run downloads the vLLM image (about 10 GB) and the model (1 GB) into `/srv/lifewatch-lab`. Both are reused later.

Ports used on the laptop: 80, 443, 8443 (ingress, loopback only), 4000 and 8080 (operator ports, loopback).
