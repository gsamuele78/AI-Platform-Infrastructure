#!/usr/bin/env bash
# Mutation tests for the policy checks (PLAN P2): each catalogue row breaks one
# thing in a throw-away copy of the repository and expects the named bats test
# to FAIL. A mutation that survives (tests stay green) or does not apply (the
# sed changed nothing) fails this run.
#   tests/mutation/run.sh [ID...]          (default: every row)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CATALOG="${REPO}/tests/mutation/catalog.tsv"
BATS="${BATS:-bats}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

want=" $* "
total=0 killed=0 bad=0
while IFS=$'\t' read -r id file expr test filter; do
  [[ -z "${id}" || "${id}" == \#* ]] && continue
  [[ "${want}" == "  " || "${want}" == *" ${id} "* ]] || continue
  total=$((total + 1))
  copy="${WORK}/${id}"
  mkdir -p "${copy}"
  # Tracked and new (not ignored) files: the tree CI would see.
  (cd "${REPO}" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "${copy}")
  sed -i -E "${expr}" "${copy}/${file}"
  if cmp -s "${REPO}/${file}" "${copy}/${file}"; then
    echo "NOT APPLIED  ${id}: '${expr}' changed nothing in ${file}"
    bad=$((bad + 1))
    continue
  fi
  (cd "${copy}" && "${BATS}" "${test}" -f "${filter}" >"${WORK}/${id}.log" 2>&1) || true
  # Killed only by a test that ran and failed: a filter that matches nothing,
  # or a bats error, must not count as a kill.
  if ! grep -q '^not ok' "${WORK}/${id}.log"; then
    echo "SURVIVED     ${id}: no test matching '${filter}' in ${test} failed"
    sed 's/^/             /' "${WORK}/${id}.log" | head -5
    bad=$((bad + 1))
  else
    echo "killed       ${id}"
    killed=$((killed + 1))
  fi
done <"${CATALOG}"

echo "mutations: ${total}, killed: ${killed}, survived or not applied: ${bad}"
[[ "${total}" -gt 0 && "${bad}" -eq 0 ]]
