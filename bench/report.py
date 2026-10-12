#!/usr/bin/env python3
"""Summarise bench/load.sh and bench/eval.py results and apply the P5 gate.

    python3 bench/report.py RESULT_DIR [BASELINE_DIR]

Per concurrency level: median and IQR over runs (ADR-013 §2) of p95 TTFT,
p95 inter-token latency and output throughput. Quality: pass rate with a
Wilson 95 % interval from eval.json. With a baseline, applies the gate from
bench/gates.json and exits 1 if it fails. Standard library only.
"""

import json
import math
import statistics
import sys
from pathlib import Path

GATES = json.loads((Path(__file__).parent / "gates.json").read_text())


def quartiles(values):
    if len(values) < 2:
        v = values[0] if values else float("nan")
        return v, v, v
    q = statistics.quantiles(values, n=4, method="inclusive")
    return q[1], q[0], q[2]


def load(result_dir):
    levels = {}
    for f in sorted(Path(result_dir).glob("c*-r*.json")):
        c = int(f.name[1:].split("-")[0])
        levels.setdefault(c, []).append(json.loads(f.read_text()))
    summary = {}
    for c, runs in sorted(levels.items()):
        def col(key):
            return [r[key] for r in runs if r.get(key) is not None]
        summary[c] = {
            "runs": len(runs),
            "failed": sum(r.get("failed", 0) for r in runs),
            "p95_ttft_ms": quartiles(col("p95_ttft_ms")),
            "p95_itl_ms": quartiles(col("p95_itl_ms")),
            "output_tok_s": quartiles(col("output_throughput")),
        }
    quality = None
    ev = Path(result_dir) / "eval.json"
    if ev.exists():
        quality = json.loads(ev.read_text())
    return summary, quality


def wilson(k, n, z=1.96):
    if n == 0:
        return float("nan"), float("nan")
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return centre - half, centre + half


def fmt(t, unit=""):
    med, lo, hi = t
    return f"{med:.1f}{unit} (IQR {lo:.1f}-{hi:.1f})"


def table(name, summary, quality):
    print(f"\n### {name}\n")
    print("| concurrency | runs | failed | p95 TTFT | p95 ITL | output tok/s |")
    print("| --: | --: | --: | :-- | :-- | :-- |")
    for c, s in summary.items():
        print(f"| {c} | {s['runs']} | {s['failed']} | {fmt(s['p95_ttft_ms'], ' ms')} "
              f"| {fmt(s['p95_itl_ms'], ' ms')} | {fmt(s['output_tok_s'])} |")
    if quality:
        lo, hi = wilson(quality["passed"], quality["attempts"])
        print(f"\nQuality: {quality['passed']}/{quality['attempts']} = "
              f"{100 * quality['passed'] / quality['attempts']:.1f} % (Wilson 95 %: {100 * lo:.1f}-{100 * hi:.1f} %); "
              f"tool calls schema-valid: {quality.get('tool_calls_valid', 0)}/{quality.get('tool_calls', 0)}")


def gate(cand, base):
    (cs, cq), (bs, bq) = cand, base
    g, ok, lines = GATES, True, []

    def check(label, passed, detail):
        nonlocal ok
        ok &= passed
        lines.append(f"| {label} | {'✔' if passed else '✘'} | {detail} |")

    if cq and bq:
        cp, bp = cq["passed"] / cq["attempts"], bq["passed"] / bq["attempts"]
        check("quality", cp >= bp - g["quality_max_drop_pp"] / 100,
              f"{100 * cp:.1f} % vs {100 * bp:.1f} % (max drop {g['quality_max_drop_pp']} pp)")
    else:
        check("quality", False, "eval.json missing in one of the two directories")
    lvl = g["latency_level"]
    if lvl in cs and lvl in bs:
        ct, bt = cs[lvl]["p95_ttft_ms"][0], bs[lvl]["p95_ttft_ms"][0]
        check(f"p95 TTFT @ c={lvl}", ct <= bt * (1 + g["ttft_max_increase_pct"] / 100) and ct <= g["ttft_abs_max_ms"],
              f"{ct:.0f} ms vs {bt:.0f} ms (≤ +{g['ttft_max_increase_pct']} %, ≤ {g['ttft_abs_max_ms']} ms)")
    else:
        check(f"p95 TTFT @ c={lvl}", False, "level not measured")
    lvl = g["throughput_level"]
    if lvl in cs and lvl in bs:
        ct, bt = cs[lvl]["output_tok_s"][0], bs[lvl]["output_tok_s"][0]
        check(f"throughput @ c={lvl} (primary)", ct >= bt * (1 - g["throughput_max_drop_pct"] / 100),
              f"{ct:.0f} vs {bt:.0f} tok/s (guard −{g['throughput_max_drop_pct']} %)")
    for s, name in ((cs, "candidate"), (bs, "baseline")):
        fails = sum(v["failed"] for v in s.values())
        check(f"no failed requests ({name})", fails == 0, f"{fails} failed")
    print("\n### Gate (bench/gates.json, ADR-013)\n\n| check | result | detail |\n| :-- | :-: | :-- |")
    print("\n".join(lines))
    print(f"\n**{'PASS' if ok else 'FAIL'}**")
    return ok


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    cand = load(argv[1])
    if not cand[0]:
        sys.exit(f"no c*-r*.json results in {argv[1]}")
    table(argv[1], *cand)
    if len(argv) == 3:
        base = load(argv[2])
        table(argv[2], *base)
        sys.exit(0 if gate(cand, base) else 1)


if __name__ == "__main__":
    main(sys.argv)
