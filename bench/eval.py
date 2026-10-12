#!/usr/bin/env python3
"""Golden-set evaluation through the gateway (PLAN P5, ADR-013).

    OPENAI_API_KEY=sk-... python3 bench/eval.py RESULT_DIR [--attempts 5]
        [--base-url http://127.0.0.1:4000] [--tasks bench/golden] [--only ID,...]

Every task in bench/golden/*.jsonl is sent ATTEMPTS times; an attempt passes
only if every check passes. Checks are deterministic (no LLM judge, ADR-013):

  contains_all  list of substrings, case-insensitive, all must appear
  contains_any  list of substrings, at least one must appear
  regex         Python regex that must match (re.S | re.I)
  number        {"value": V, "tol": T}: some number in the answer within T of V
  json_keys     the answer (or its first {...} block) is a JSON object with these keys
  tool_call     {"name": N, "args": {k: v}}: first tool call is N, arguments are
                a JSON object containing these key/values (strings compared
                case-insensitively)
  no_tool_call  true: the model must answer without calling a tool

Writes RESULT_DIR/eval.json (read by bench/report.py). Standard library only.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def chat(base, key, model, task, timeout=600):
    body = {"model": model, "messages": task["messages"], "max_tokens": task.get("max_tokens", 4096)}
    for k in ("tools", "tool_choice", "temperature", "chat_template_kwargs"):
        if k in task:
            body[k] = task[k]
    req = urllib.request.Request(
        f"{base}/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.load(r)
    return data["choices"][0]["message"], time.monotonic() - t0


def first_json_object(text):
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        m = re.search(r"\{.*\}", text or "", re.S)
        if not m:
            return None
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            return None


def check(task, msg):
    """Return (passed, reason, tool_call_seen, tool_call_valid)."""
    content = msg.get("content") or ""
    calls = msg.get("tool_calls") or []
    seen = valid = 0
    for c in calls:
        seen += 1
        try:
            if isinstance(json.loads(c["function"]["arguments"] or "{}"), dict):
                valid += 1
        except (KeyError, TypeError, json.JSONDecodeError):
            pass
    low = content.lower()
    for kind, want in task["check"].items():
        if kind == "contains_all":
            miss = [w for w in want if w.lower() not in low]
            if miss:
                return False, f"missing {miss}", seen, valid
        elif kind == "contains_any":
            if not any(w.lower() in low for w in want):
                return False, f"none of {want}", seen, valid
        elif kind == "regex":
            if not re.search(want, content, re.S | re.I):
                return False, f"no match /{want}/", seen, valid
        elif kind == "number":
            nums = [float(x.replace(",", ".")) for x in re.findall(r"-?\d+(?:[.,]\d+)?", content)]
            if not any(abs(n - want["value"]) <= want["tol"] for n in nums):
                return False, f"no number within {want['tol']} of {want['value']}", seen, valid
        elif kind == "json_keys":
            obj = first_json_object(content)
            if not isinstance(obj, dict) or not set(want) <= set(obj):
                return False, f"not a JSON object with {want}", seen, valid
        elif kind == "tool_call":
            if not calls:
                return False, "no tool call", seen, valid
            fn = calls[0].get("function", {})
            if fn.get("name") != want["name"]:
                return False, f"called {fn.get('name')}", seen, valid
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                return False, "arguments are not JSON", seen, valid
            for k, v in want.get("args", {}).items():
                got = args.get(k)
                if isinstance(v, str) and isinstance(got, str):
                    if v.lower() != got.lower():
                        return False, f"{k}={got!r}", seen, valid
                elif got != v:
                    return False, f"{k}={got!r}", seen, valid
        elif kind == "no_tool_call":
            if calls:
                return False, "unexpected tool call", seen, valid
        else:
            return False, f"unknown check {kind}", seen, valid
    return True, "", seen, valid


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("result_dir")
    ap.add_argument("--attempts", type=int, default=5)
    ap.add_argument("--base-url", default=os.environ.get("LW_GATEWAY_URL", "http://127.0.0.1:4000"))
    ap.add_argument("--model", default="lifewatch-chat")
    ap.add_argument("--tasks", default=str(Path(__file__).parent / "golden"))
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    key = os.environ.get("OPENAI_API_KEY") or sys.exit("set OPENAI_API_KEY (scripts/ops/issue-key.sh --alias bench)")
    only = set(filter(None, a.only.split(",")))

    tasks = []
    for f in sorted(Path(a.tasks).glob("*.jsonl")):
        for line in f.read_text().splitlines():
            if line.strip() and not line.startswith("//"):
                t = json.loads(line)
                t.setdefault("set", f.stem)
                if not only or t["id"] in only:
                    tasks.append(t)
    if not tasks:
        sys.exit("no tasks")

    out = {"attempts": 0, "passed": 0, "tool_calls": 0, "tool_calls_valid": 0, "tasks": {}}
    for t in tasks:
        rec = {"set": t["set"], "passed": 0, "attempts": 0, "fail_reasons": [], "latency_s": []}
        for _ in range(a.attempts):
            rec["attempts"] += 1
            try:
                msg, dt = chat(a.base_url, key, a.model, t)
                ok, why, seen, valid = check(t, msg)
                rec["latency_s"].append(round(dt, 2))
            except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError) as e:
                ok, why, seen, valid = False, f"request error: {e}", 0, 0
            out["tool_calls"] += seen
            out["tool_calls_valid"] += valid
            if ok:
                rec["passed"] += 1
            elif why not in rec["fail_reasons"]:
                rec["fail_reasons"].append(why)
        out["attempts"] += rec["attempts"]
        out["passed"] += rec["passed"]
        out["tasks"][t["id"]] = rec
        print(f"{t['id']:<32} {rec['passed']}/{rec['attempts']}  {'; '.join(rec['fail_reasons'])[:100]}", flush=True)

    Path(a.result_dir).mkdir(parents=True, exist_ok=True)
    (Path(a.result_dir) / "eval.json").write_text(json.dumps(out, indent=2))
    print(f"\n{out['passed']}/{out['attempts']} attempts passed; "
          f"tool calls schema-valid {out['tool_calls_valid']}/{out['tool_calls']}")


if __name__ == "__main__":
    main()
