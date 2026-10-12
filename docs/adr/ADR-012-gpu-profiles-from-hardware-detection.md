# ADR-012: GPU Profiles Selected by Hardware Detection

**Status:** Accepted 2026-10-12, implemented (`profiles/`, `scripts/lib/profile.sh`, `--gpu` in `scripts/pve/*`; `tests/vm/profile.bats`, `tests/pve/*.bats`). Profiles stay `candidate` until PLAN P5 validates them. Amends ADR-003 (topology) and AC-1.1, AC-2.1, AC-3.1.

## Context

- The target is now **two hosts** (owner decision, 2026-10-12): this platform runs in a VM on Proxmox with **one or two** L40S. The second L40S may move to another server for TensorFlow/ML compute, but only if a benchmark shows it is worth it (ADR-015).
- Everything today assumes exactly two GPUs: `LW_EXPECTED_GPUS=2` in `scripts/lib/pve.sh`, `vm-check.sh`, `release.env` (72B, TP=2), AC-1.1, AC-2.1 (finding R3-05).
- Qwen2.5-72B FP8 (75.2 GB) cannot run on one L40S (40.5 GiB budget). With one GPU the model must change (PRACTICES_EVALUATION §4).
- AiAgentInfrastructure (ADR-0023 there) already picks the local model from detected hardware. Its lessons apply here: count GPUs on the PCI bus rather than by `command -v nvidia-smi`, and choose only among models the gateway knows.

## Decision

1. **Profiles are files, reviewed in git:** `profiles/l40s-1.env`, `profiles/l40s-2.env`, `profiles/lab.env`. Each one holds the model id and revision, TP size, context, KV dtype, tool and reasoning parsers, and capacity limits. `release.env` keeps only what is common to all profiles.
2. **Detection only selects, never invents.** `scripts/vm/detect-profile.sh` (guest) reports GPU count by PCI id, VRAM, compute capability and driver, and maps them through a fixed table to a profile. Unknown hardware (for example 1 × A100, or 3 GPUs) **fails** with the facts printed. There is no "best effort" model.
3. **A profile is deployable only once validated.** A profile becomes `validated` only after its AC-3.1 record (GPU blocks, eval results per ADR-013) has been committed. Preflight refuses a profile that is not validated unless `--allow-unvalidated` is passed, which is used only in the lab.
4. **Alias stability:** the served name stays `lifewatch-chat` in every profile, so clients and `configs/proxy/config.yaml` never change. The context limit and capabilities a client can rely on are published per profile (ADR-014).
5. **Detection runs in preflight** and its result is written into the release metadata. A change of profile is an ordinary deploy, with the model reload as its downtime, and is rolled back like any release.
6. **Host side:** `LW_EXPECTED_GPUS` accepts 1 or 2, and `configure-passthrough.sh` gains `--gpu <BDF>` (repeatable) to pass a subset. The second card can then go to another VM on the same host. The vfio-pci binding by PCI id stays: on the host both cards are passthrough-only either way.

## Alternatives considered

- **Auto-pick the largest model that fits:** it maximises size, not quality or agent fitness, and deploys models nobody evaluated (the F-01 class of error).
- **One fixed model for both profiles** (a model that fits on one GPU, also used on two): simpler, but it wastes the second GPU's KV capacity, unless the eval shows the same model is best on both. That remains a possible outcome of P5.
- **Kubernetes device plugin / GPU operator:** a control plane for one VM (rejected in ADR-010 for the same reason).

## Consequences

- Positive: the same repository deploys on either hardware outcome of ADR-015, and refuses hardware it has never seen.
- Negative: two profiles means two AC-3.1 records and two eval runs, and twice the work on every vLLM upgrade. With one GPU, NCCL and TP disappear, but so does about half of the KV capacity.
- The 72B may survive only in the 2-GPU profile, and only if P5 shows it still wins.
