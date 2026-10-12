# ADR-007: Storage Layer Separation for Model Weights & Application State

**Status:** Accepted — implemented by `scripts/ops/backup.sh` / `restore.sh`; off-host copy pending (DEC-006).

## Context
Model weights require multi-hundred gigabyte storage, whereas databases and UI state require backed-up persistent volumes.

## Decision
Mount `/data/vllm_cache` on a dedicated NVMe volume (excluded from routine VM backups) and store Open WebUI and LiteLLM state on backed-up persistent Docker volumes.

## Rationale
Prevents redundant, expensive backups of publicly downloadable HuggingFace model weights while safeguarding user data.
