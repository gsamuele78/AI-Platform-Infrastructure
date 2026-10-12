#!/usr/bin/env bats
# .claude/settings.json: agents may not read secrets and must ask before any
# command that changes a host, a release or its data (audit R3-08).

load ../helpers/common

SETTINGS="${REPO_ROOT}/.claude/settings.json"

rules() { jq -r ".permissions.$1[]" "${SETTINGS}"; }

@test "settings file is valid JSON" {
  jq -e .permissions "${SETTINGS}" >/dev/null
}

@test "secret locations are denied to agents" {
  local want
  for want in 'Read(./.env)' 'Read(**/*.pem)' 'Read(**/*.key)' 'Read(**/.vagrant/**)' \
    'Read(**/live/**)' 'Read(**/lifewatch-backups/**)'; do
    rules deny | grep -qxF "${want}" || { echo "missing deny: ${want}"; false; }
  done
}

@test "non-secret env files stay readable (release profiles, CI and lab fixtures)" {
  run rules deny
  [[ "${output}" != *'*.env)'* && "${output}" != *'.env.*)'* ]]
}

@test "mutating commands require confirmation" {
  local want
  for want in 'Bash(*--apply*)' 'Bash(make deploy*)' 'Bash(make rollback*)' \
    'Bash(*scripts/ops/restore.sh*)' 'Bash(qm *)' 'Bash(pvesh *)' 'Bash(*docker compose*down*)'; do
    rules ask | grep -qxF "${want}" || { echo "missing ask: ${want}"; false; }
  done
}
