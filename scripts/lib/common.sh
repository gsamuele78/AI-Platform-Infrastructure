#!/usr/bin/env bash
# Shared helpers for every LifeWatch operational script. Source, don't execute.
# Conventions: messages go to stderr with a [LEVEL] tag; die() exits non-zero;
# nothing here mutates the system.

[[ -n "${_LW_COMMON_SH:-}" ]] && return 0
_LW_COMMON_SH=1

LW_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LW_REPO_ROOT

LW_WARNINGS=0

log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }
info() { log INFO "$@"; }
pass() { log PASS "$@"; }
warn() {
  LW_WARNINGS=$((LW_WARNINGS + 1))
  log WARN "$@"
}
fail() { log FAIL "$@"; }
die() {
  log FAIL "$@"
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This command must run as root."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "Required command not found: ${c}"
  done
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# manifest_get FILE KEY: read KEY=value from a manifest without sourcing it
# (sourcing a file as root would turn a tampered backup into code execution).
manifest_get() {
  local file=$1 key=$2 line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"${file}"
  return 1
}

# confirm PROMPT: interactive yes/no; LW_ASSUME_YES=1 answers yes.
confirm() {
  [[ "${LW_ASSUME_YES:-0}" == 1 ]] && return 0
  local reply
  read -r -p "$1 [type 'yes' to continue] " reply
  [[ "${reply}" == yes ]]
}
