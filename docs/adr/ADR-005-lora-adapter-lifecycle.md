# ADR-005: Governance & Lifecycle for LoRA Adapters

**Status:** Accepted — **not implemented**.

## Context
Researchers require custom domain adapters without deploying independent, unmonitored model server instances.

## Decision
Implement an administrative LoRA registration workflow. Adapters must be verified for base-model compatibility, security-scanned, and registered in the LiteLLM catalog.

## Rationale
Prevents arbitrary execution and unmonitored VRAM consumption from unverified user-uploaded weights.

## Consequences
Users cannot load arbitrary adapter weights dynamically without administrative approval.
