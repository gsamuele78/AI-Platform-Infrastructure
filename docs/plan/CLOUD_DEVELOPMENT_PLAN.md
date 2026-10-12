# Cloud Development Plan: Claude Code on the Web vs a claude.ai Project

| | |
| :-- | :-- |
| **Date** | 2026-10-12 |
| **Question** | Is it worth moving the development of this repository to Anthropic's cloud, or should it continue locally only? |
| **Sources** | code.claude.com/docs: `claude-code-on-the-web`, `cloud-environments`, `self-hosted-environments` (read 2026-10-12) |
| **Short answer** | **Yes, for about two thirds of [PLAN.md](PLAN.md):** Claude Code on the web for the host-independent packages, local sessions for anything that touches a GPU, libvirt or the Proxmox host. A claude.ai Project is useful only as a discussion space for the decisions, not for development. The pilot (C0) has to confirm this before anything else moves. |

## 1. The two options

| | Claude Code on the web (cloud sessions) | claude.ai Project |
| :-- | :-- | :-- |
| What it is | Claude Code running in an Anthropic-hosted Ubuntu 24.04 VM. It clones the GitHub repo, runs commands, pushes branches and opens PRs. Sessions can be started from the browser, phone or desktop, moved with `--teleport`, and scheduled as routines | Chat with project knowledge (uploaded files or synced GitHub files) and custom instructions |
| Runs code | yes: Docker, docker compose, Python, git, gh, jq, yq preinstalled; `apt install` in a setup script that runs as root | no |
| Resources | 4 vCPU, 16 GB RAM, 30 GB disk | — |
| Network | levels None / Trusted / Full / Custom. "Trusted" includes ghcr.io, Docker Hub, GitHub, PyPI and the Ubuntu archives. huggingface.co is not among the defaults the docs list (needs Custom; not required here) | — |
| GPU, KVM/libvirt | not documented, so treated as **unavailable** | — |
| Repo context | `AGENTS.md`, `CLAUDE.md` and `.claude/settings.json` from the repo. Local memory does not travel | project instructions + knowledge files |
| Fit for this repo | implementation, tests, PRs for P0-P4, P6, P7, P9, P11 | reviewing ADRs and DEC decisions with people who do not use Git (research lead, IT Security) |

## 2. What can run where

| Work | Cloud session | Local (laptop / host) | Why |
| :-- | :-- | :-- | :-- |
| `make lint`, `make test` (bats, shellcheck, compose render) | ✅ | ✅ | needs only apt packages and Docker CLI |
| `make integration` (real gateway/UI/DB, fake GPU, Pebble) | ✅ **to be proven in C0** | ✅ | Docker is available; container hardening (`cap_drop`, `no-new-privileges`) inside the sandbox is untested; images from ghcr.io/Docker Hub are on the Trusted list |
| `make secrets` (gitleaks image) | ✅ | ✅ | ghcr.io |
| Trivy (P1) | ⚠️ the DB download host may need a Custom allowlist | ✅ | |
| `make vm-test` (vagrant-libvirt) | ❌ | ✅ | nested virtualisation not documented |
| `make lab-gpu`, P3 lab step, P5, P5b, AC-3.1 | ❌ | ✅ | GPU, and Hugging Face downloads |
| Proxmox passthrough (real) | ❌ | ✅ host | hardware |
| Package mapping | P0, P1, P2, P3 (code), P4 (fixtures), P6 (config), P7 (Pebble), P9, P11 | P3 lab, P5, P5b, P8 apply, P10, every `--apply` on real systems | |

## 3. Is it worth it? Pre-registered pilot (ADR-013)

The cloud setup is adopted only if a pilot shows it pays off. Pilot = package **P0** done in a cloud session, compared with the same kind of work done locally (P0 is small and host-independent).

| Metric | Target | Guard |
| :-- | :-- | :-- |
| `make lint test` in a cloud session | passes, median ≤ 10 min over 5 sessions (cached setup) | — |
| `make integration` in a cloud session | passes in ≥ 4 of 5 runs | if it fails for sandbox reasons, cloud sessions are limited to lint/test and integration stays in GitHub Actions; that is still useful |
| Maintainer time per package (from start to PR ready for review) | ≤ local time | must not grow |
| Secrets exposed to the cloud session | 0 | the repo is public and CI uses throwaway values; nothing real is needed |

If the pilot misses the targets, development continues locally, and this file records why.

## 4. Steps

### C0. Prerequisites in the repo (part of PLAN P0)

- `AGENTS.md` and `CLAUDE.md`: cloud sessions start without local memory, so the context must live in the repository.
- `.claude/settings.json` with `permissions.deny` and `permissions.ask` (PLAN P0). Cloud sessions read it from the repo.

### C1. Environment

- Connect GitHub (GitHub App) for `gsamuele78/AI-Platform-Infrastructure`.
- Create one environment, `ai-platform-ci`: network **Trusted**, plus a Custom entry only if the Trivy DB host turns out to be blocked; no environment variables (nothing secret is needed).
- Setup script (runs as root on Ubuntu 24.04; cached when it finishes in about 5 minutes):

```bash
#!/usr/bin/env bash
set -euo pipefail
apt-get update -q
apt-get install -y -q --no-install-recommends bats shellcheck
# Pull the integration images once, so the cached snapshot has them on disk.

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true
if [ -f compose.yaml ] && [ -f .env.example ]; then
  docker compose --env-file profiles/l40s-2.env --env-file .env.example pull --ignore-pull-failures \
    litellm-gateway open-webui postgres ingress || true
fi
```

  The docs do not say which directory the setup script starts in, hence the guarded `cd`; check the session log in C2. The script pulls only the images the integration test runs, never `vllm-backend` (about 10 GB, and not used without a GPU). If the pull pushes setup past the 5-minute cache window, drop it and let sessions pull on demand.

### C2. Pilot

- Run P0 from claude.ai/code with the prompt "Implement PLAN.md P0. Run make lint test integration before opening the PR. Fill the P0 row in PLAN.md §4."
- Record the five pilot runs in the register (PLAN §4), using the metrics of §3.

### C3. Working pattern, if the pilot passes

- **One package, one cloud session, one PR.** Sessions can run in parallel when the packages do not touch the same files (for example P1 and P11).
- **Host steps stay local.** When a package needs the lab or the host, `claude --teleport <session>` brings the session to the laptop, which runs `make lab-gpu` or `make vm-test` and pushes the results to the same branch.
- **Routines (optional, after P1):** one weekly routine that reads the newest vLLM, LiteLLM and Open WebUI release notes against the pinned versions and opens an issue listing removed flags or migrations (the RUNBOOK §8 check, done before a Dependabot PR is reviewed). No routine ever deploys.
- **Review stays human.** Cloud sessions open PRs. Merging needs green CI and the owner's review, as now.

### C4. claude.ai Project (optional, low cost)

- One Project, "LifeWatch AI Platform: decisions", holding `PLAN.md`, `PRACTICES_EVALUATION.md`, ADR-012…015 and `DECISIONS_REQUIRED.md`. Use it to prepare the DEC-008/009 discussions and the golden set (P5) with the research lead.
- It never becomes the source of truth: decisions land in the repo as DEC rows or ADRs.

## 5. Risks and limits

| Risk | Mitigation |
| :-- | :-- |
| Cloud sessions share the account's rate limits with every other Claude usage | run at most two in parallel; large measurement work is host-bound anyway |
| Sandbox behaviour differs from GitHub Actions for Docker integration | the pilot measures it; CI stays the merge gate |
| Public repo + agent with push rights | branch protection on `main`, PRs only; `.claude/settings.json` ask/deny rules |
| "When running with network access disabled, Claude Code can still communicate with the Anthropic API" (docs) | nothing confidential is in the repo or the environment: the repo is already public and secrets never enter cloud sessions |
| Self-hosted environments (sessions on own hardware, for example the GPU host) | Team/Enterprise plans only; not assumed here |
