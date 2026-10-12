# P5 Benchmark: Validating a GPU Profile on the L40S Host

Turns a profile from `PROFILE_STATUS=candidate` into `validated` ([ADR-012](../docs/adr/ADR-012-gpu-profiles-from-hardware-detection.md) §3). The protocol is [ADR-013](../docs/adr/ADR-013-measure-before-adopting.md), and the candidates are listed in [MODEL_SELECTION.md §6](../docs/plan/MODEL_SELECTION.md#6-what-p5-must-measure-before-profile_statusvalidated).

| Tool | Measures |
| :-- | :-- |
| `load.sh` | `vllm bench serve` through the gateway, at concurrency 1/8/32, 5 runs. Records p95 TTFT, p95 inter-token latency, output tokens/s, and vLLM's start-up capacity lines (AC-3.1) |
| `eval.py` | golden set in `golden/*.jsonl`, 5 attempts per task, deterministic checks only. Pass rate and tool-call validity |
| `report.py` | median and IQR per level, Wilson interval for quality; with a baseline directory, applies `gates.json` and exits 1 on FAIL |
| `gates.json` | the pre-registered thresholds. Change them by PR **before** any result is seen |

## Before the first window

1. **Golden set:** the research lead adds ≥ 40 real research prompts as `golden/research-*.jsonl`, each with a deterministic check (see `eval.py` for the check kinds). The `seed-science.jsonl` and `agent.jsonl` files are only a start. Agree the set, merge it, then do not change it during P5.
2. **Weights:** stage every model to be compared (`LW_PROFILE=... scripts/vm/fetch-model.sh`; for a challenger, a profile file on a branch).
3. **Key:** `KEY=$(sudo bash scripts/ops/issue-key.sh --alias bench --duration 7d)`, with no limits.

## One variant (repeat per variant, ABBA order: baseline, candidate, candidate, baseline)

```bash
sudo LW_ALLOW_UNVALIDATED=true make deploy                  # the variant's profile
export OPENAI_API_KEY="$KEY"
sudo -E bash bench/load.sh --label l40s-1-qwen38-a          # ~30-60 min
python3 bench/eval.py /var/lib/lifewatch/bench/l40s-1-qwen38-a
python3 bench/report.py /var/lib/lifewatch/bench/l40s-1-qwen38-a /var/lib/lifewatch/bench/l40s-1-baseline-a
```

Each variant switch is a model reload (5-15 min), so announce a maintenance window.

## After

- Copy the report tables into the register in [PLAN.md §4](../docs/plan/PLAN.md#4-measurement-register-fill-in-protocol-adr-013), with the run count and, for a FAIL, the reason.
- On PASS: a PR sets `PROFILE_STATUS=validated` in `profiles/<profile>.env` and attaches `capacity.txt` and the report as the AC-3.1 record.
- Raw results stay on the host or in a private location: they must not contain host names (the repository is public).
