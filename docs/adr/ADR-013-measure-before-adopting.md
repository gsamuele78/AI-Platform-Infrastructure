# ADR-013: Measure Before Adopting

**Status:** Accepted 2026-10-12. Applied by [PLAN.md](../plan/PLAN.md) (every package has a measurement row).

## Context

The 2026-10 review ([PRACTICES_EVALUATION.md](../plan/PRACTICES_EVALUATION.md)) collected about 30 candidate practices and four candidate models from AiAgentInfrastructure, Infra-Iam-PKI and OpenHands. Each comes with a claimed benefit ("faster", "better for agents", "safer"). The audit culture of this repository already rejects unverified claims (PRODUCTION_READINESS_AUDIT, "Method"). That rule needs a written protocol before the model choice, where a wrong call costs researchers answer quality.

AiAgentInfrastructure solved the same problem in its ADR-0021 (MIT). This ADR adapts that protocol to an inference platform.

## Decision

1. **Pre-registration.** Before a change is measured, the PR states the metric, the baseline, the target and the guard metrics with their tolerances. Changing a threshold after seeing the numbers needs a new PR saying why.
2. **Repetition.** Performance numbers come from ≥ 5 runs per variant, alternated ABBA, reported as median and IQR, never a single run. Pass rates use ≥ 20 attempts and report a Wilson interval.
3. **Fixed metric columns**, so results compare across packages:

| Family | Metric | Source |
| :-- | :-- | :-- |
| Capacity | cacheable tokens (`# GPU blocks` × block size), max context served | vLLM start-up log |
| Latency | TTFT p50/p95, inter-token latency p50/p95 at concurrency 1, 8, 32 | `vllm bench serve` (pinned dataset and lengths) |
| Throughput | output tokens/s at concurrency 1, 8, 32 | same |
| Quality | golden-set pass rate with **deterministic** checks; tool-call schema validity | `bench/` (PLAN P5) |
| Operations | deploy time, model load time, rollback time, changes on a 2nd identical run (must be 0) | deploy logs, `hyperfine` |
| Security | policy checks with a mutation test; secret globs readable by agents | `tests/`, `tests/mutation/` |

4. **Adoption gate.** Adopt only if the primary metric reaches its target **and** no guard metric degrades beyond its tolerance (defaults: quality −2 pp, p95 TTFT +20 %, throughput −10 %) **and** no invariant in `AGENTS.md` breaks.
5. **Register.** Every result, including failures and "not run", goes into the register in PLAN.md with date, runs and raw-output location. Raw results stay local or in CI artefacts, without host names or internal addresses (the repository is public).

## Alternatives considered

- **Adopt on reputation** (upstream recommendation, popularity): fast, and it is how F-01/F-02 happened (a model id that did not exist and a context that did not fit).
- **LLM-as-judge for quality:** cheap to scale, but it adds a second model whose bias is unmeasured. It is allowed only as a secondary signal, never as the gate.

## Consequences

- Positive: the model decision (DEC-009) and the GPU split (DEC-008, ADR-015) become reproducible arguments instead of opinions. A Dependabot bump can be compared with the last baseline.
- Negative: measurements on the L40S cost maintenance windows (each model swap is a 5-15 minute reload). Pre-registration adds work to every PR. The golden set is small and local: a pass on it does not generalise, and every report must say so.
