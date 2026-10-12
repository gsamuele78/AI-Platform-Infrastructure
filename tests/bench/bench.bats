#!/usr/bin/env bats
# P5 benchmark harness: deterministic checks, golden-set validity, and the
# pre-registered gate (ADR-013). No GPU or network needed.

load ../helpers/common

PY() { python3 -I - "$@"; }

@test "every golden task is valid JSON with known check kinds and a unique id" {
  run PY "${REPO_ROOT}/bench/golden" <<'EOF2'
import json, sys
from pathlib import Path
known = {"contains_all","contains_any","regex","number","json_keys","tool_call","no_tool_call"}
ids = set()
for f in Path(sys.argv[1]).glob("*.jsonl"):
    for line in f.read_text().splitlines():
        if not line.strip() or line.startswith("//"): continue
        t = json.loads(line)
        assert t["id"] not in ids, t["id"]; ids.add(t["id"])
        assert t["check"] and set(t["check"]) <= known, (t["id"], t["check"])
        assert t["messages"], t["id"]
print(len(ids))
EOF2
  assert_status 0
  [[ "${output}" -ge 20 ]]
}

@test "checks pass on a correct answer and fail on a wrong one" {
  run PY "${REPO_ROOT}/bench" <<'EOF2'
import sys; sys.path.insert(0, sys.argv[1])
from eval import check
call = lambda n, a: {"content": None, "tool_calls": [{"function": {"name": n, "arguments": a}}]}
t = {"check": {"tool_call": {"name": "get_weather", "args": {"city": "Bologna"}}}}
assert check(t, call("get_weather", '{"city": "bologna"}'))[0]
assert not check(t, call("get_weather", '{"city": "Roma"}'))[0]
assert not check(t, call("other", '{"city": "Bologna"}'))[0]
assert not check(t, call("get_weather", 'not json'))[0]
assert not check(t, {"content": "sunny"})[0]
n = {"check": {"number": {"value": 1.040, "tol": 0.002}}}
assert check(n, {"content": "H' = 1,040"})[0] and not check(n, {"content": "H' = 1.05"})[0]
j = {"check": {"json_keys": ["a", "b"]}}
assert check(j, {"content": "Here: {\"a\": 1, \"b\": 2}"})[0] and not check(j, {"content": "{\"a\": 1}"})[0]
nt = {"check": {"no_tool_call": True}}
assert check(nt, {"content": "144"})[0] and not check(nt, call("x", "{}"))[0]
assert check(t, call("get_weather", '{"city": "Bologna"}'))[2:] == (1, 1)
print("ok")
EOF2
  assert_status 0
  [[ "${output}" == ok ]]
}

# synth DIR P95_TTFT_C8 TOK_S_C32 PASSED: fake load.sh + eval.py results, 5 runs
synth() {
  mkdir -p "$1"
  local r c
  for r in 1 2 3 4 5; do
    for c in 8 32; do
      printf '{"failed":0,"p95_ttft_ms":%s,"p95_itl_ms":40,"output_throughput":%s}\n' "$2" "$3" >"$1/c${c}-r${r}.json"
    done
  done
  printf '{"attempts":100,"passed":%s,"tool_calls":10,"tool_calls_valid":10}\n' "$4" >"$1/eval.json"
}

@test "gate passes when the candidate holds quality, latency and throughput" {
  synth "${BATS_TEST_TMPDIR}/base" 1000 500 80
  synth "${BATS_TEST_TMPDIR}/cand" 1100 600 79
  run python3 "${REPO_ROOT}/bench/report.py" "${BATS_TEST_TMPDIR}/cand" "${BATS_TEST_TMPDIR}/base"
  assert_status 0
  assert_output_contains "**PASS**"
}

@test "gate fails on a quality drop beyond 2 pp, slow TTFT, or lost throughput" {
  synth "${BATS_TEST_TMPDIR}/base" 1000 500 80
  synth "${BATS_TEST_TMPDIR}/q" 1000 500 77
  run python3 "${REPO_ROOT}/bench/report.py" "${BATS_TEST_TMPDIR}/q" "${BATS_TEST_TMPDIR}/base"
  assert_failure
  synth "${BATS_TEST_TMPDIR}/t" 1300 500 80
  run python3 "${REPO_ROOT}/bench/report.py" "${BATS_TEST_TMPDIR}/t" "${BATS_TEST_TMPDIR}/base"
  assert_failure
  synth "${BATS_TEST_TMPDIR}/x" 1000 400 80
  run python3 "${REPO_ROOT}/bench/report.py" "${BATS_TEST_TMPDIR}/x" "${BATS_TEST_TMPDIR}/base"
  assert_failure
  assert_output_contains "**FAIL**"
}

@test "load.sh refuses to run without a benchmark key or with a bad label" {
  run env -u OPENAI_API_KEY bash "${REPO_ROOT}/bench/load.sh" --label x
  assert_failure
  assert_output_contains "OPENAI_API_KEY"
  run bash "${REPO_ROOT}/bench/load.sh" --label 'a;b'
  assert_failure
}
