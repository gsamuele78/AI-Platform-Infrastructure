# shellcheck shell=bash disable=SC2016,SC2154 # stub bodies are literal code; $output/$status come from bats
# Shared bats helpers.
# Every external command a script touches (qm, lspci, docker, curl, id, ...) is
# replaced by a stub on PATH that logs its argv to $STUB_LOG, so tests assert on
# behaviour (what was called, what was written) without needing real hardware.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
export REPO_ROOT

setup_sandbox() {
  SANDBOX="${BATS_TEST_TMPDIR}"
  STUB_BIN="${SANDBOX}/bin"
  mkdir -p "${STUB_BIN}"
  export PATH="${STUB_BIN}:${PATH}"
  export STUB_LOG="${SANDBOX}/calls.log"
  : >"${STUB_LOG}"
  export SANDBOX STUB_BIN
}

# stub NAME [BODY]: create an executable NAME that logs "NAME args" then runs BODY.
stub() {
  local name=$1 body=${2:-}
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "%s $*" >>"$STUB_LOG"\n' "${name}"
    printf '%s\n' "${body}"
  } >"${STUB_BIN}/${name}"
  chmod +x "${STUB_BIN}/${name}"
}

as_root() { stub id 'if [[ "${1:-}" == "-u" ]]; then echo 0; else /usr/bin/id "$@"; fi'; }
as_user() { stub id 'if [[ "${1:-}" == "-u" ]]; then echo 1000; else /usr/bin/id "$@"; fi'; }

# called NAME PATTERN: true if a stub NAME was invoked with args matching the ERE.
called() { grep -Eq "^$1 .*$2" "${STUB_LOG}"; }
not_called() { ! grep -Eq "^$1( |$)" "${STUB_LOG}"; }

assert_output_contains() {
  if [[ "${output}" != *"$1"* ]]; then
    printf 'expected output to contain: %s\n--- output ---\n%s\n' "$1" "${output}" >&2
    return 1
  fi
}

assert_status() {
  if [[ "${status}" -ne "$1" ]]; then
    printf 'expected status %s, got %s\n--- output ---\n%s\n' "$1" "${status}" "${output}" >&2
    return 1
  fi
}

assert_failure() {
  if [[ "${status}" -eq 0 ]]; then
    printf 'expected failure, got status 0\n--- output ---\n%s\n' "${output}" >&2
    return 1
  fi
}
