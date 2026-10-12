# ADR-015: Allocation of the Second L40S Decided by Benchmark

**Status:** Proposed 2026-10-12. Decision record: DEC-008. Measurement: [PLAN.md](../plan/PLAN.md) P5 (LLM side) and P5b (TensorFlow side). Protocol: ADR-013.

## Context

The owner may attach one of the two L40S to another server for TensorFlow/ML compute, "if it is worth it and testing shows a real increase of performance instead of using only CPU-based calculation" (2026-10-12). Both sides lose or gain something:

- **TensorFlow side:** gain = the speed-up of the actual research workloads on an L40S compared with that server's CPUs, weighted by how many hours they really run.
- **LLM side:** loss = moving from the 2-GPU to the 1-GPU profile (ADR-012): about half the KV capacity, possibly a smaller model, and lower concurrency for researchers and agents.

If only one side is measured, the decision follows whichever side happened to be benchmarked.

## Decision

The card moves only if **both** pre-registered conditions hold:

1. **TensorFlow gain (P5b):** on ≥ 3 representative research jobs chosen by the research lead (training and inference, real data sizes), median wall-clock speed-up L40S vs CPU-only ≥ **5×**, *and* projected GPU-busy time ≥ **20 %** of working hours over a typical month. A fast card that sits idle does not count.
2. **LLM loss is acceptable (P5):** the best validated 1-GPU profile, compared with the best 2-GPU profile on the same golden set and load, keeps:
   - quality within −2 pp,
   - p95 TTFT ≤ 3 s at the measured peak concurrency (from LiteLLM spend logs or the expected user count),
   - context ≥ 64k (ADR-014).

The thresholds can still be changed in the pre-registration PR, before any number is seen (ADR-013 §1).

Mechanics, whichever way it goes:
- **Card stays:** this VM keeps both GPUs (`l40s-2` profile). The TensorFlow server keeps its CPUs, and the decision is revisited if its workload grows.
- **Card moves to another VM on the same Proxmox host:** `configure-passthrough.sh --gpu <BDF>` for each VM (ADR-012 §6). This VM redeploys with `l40s-1`.
- **Card moves to another physical server:** physical change in a maintenance window, then preflight on both hosts. This VM redeploys with `l40s-1`. Setting up that server is out of scope of this repository.

## Alternatives considered

- **Time-sharing the second GPU** (LLM by day, TensorFlow by night, by stopping vLLM): vLLM's reload costs 5-15 minutes each switch, and the profiles would change twice a day. Revisit only if P5b shows a strongly nightly workload.
- **MIG partitioning:** the L40S does not support MIG.
- **vGPU:** licence cost and complexity (rejected in ADR-002).

## Consequences

- Positive: the hardware decision has numbers on both sides and can be explained to the research group.
- Negative: P5b needs the research lead's time to choose jobs, and a temporary GPU host for the TensorFlow runs. The LLM side needs both profiles validated on the real host before the decision, which means at least two maintenance windows.
