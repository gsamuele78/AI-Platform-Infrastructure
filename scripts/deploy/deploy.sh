#!/usr/bin/env bash
# Deploy the committed working tree as a new immutable release.
#   deploy.sh [--allow-dirty] [--no-auto-rollback] [--skip gpu,model]
#
#  1. refuse uncommitted changes (what runs must be what was reviewed)
#  2. snapshot compose.yaml + release.env + configs/ into releases/<id>
#  3. preflight the snapshot (secrets, config, weights, GPUs)
#  4. back up all state if a release is already running
#  5. pull images (failure here changes nothing)
#  6. up --wait: cut over, block until every healthcheck is green
#  7. smoke test (auth 401, model listed, real inference, UI health)
#  8. success -> releases/current; failure -> automatic rollback (rollback.sh)
# Honest limit: one GPU pair cannot hold two 72B replicas, so a vLLM change
# means downtime equal to the model load time. There is no blue/green here.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

ALLOW_DIRTY=false
AUTO_ROLLBACK=true
SKIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    --no-auto-rollback)
      AUTO_ROLLBACK=false
      shift
      ;;
    --skip)
      SKIP=$2
      shift 2
      ;;
    *) die "Usage: $0 [--allow-dirty] [--no-auto-rollback] [--skip gpu,model]" ;;
  esac
done

if [[ -n "$(git -C "${LW_REPO_ROOT}" status --porcelain --untracked-files=no)" ]]; then
  [[ "${ALLOW_DIRTY}" == true ]] || die "Working tree has uncommitted changes; commit them (or pass --allow-dirty for a lab deploy)"
  warn "Deploying uncommitted changes (--allow-dirty)"
fi
GIT_SHA="$(git -C "${LW_REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo nogit)"

mkdir -p "${LW_RELEASES_DIR}"
chmod 0700 "${LW_STATE_DIR}"
ID="$(timestamp)-${GIT_SHA}"
REL="$(release_dir "${ID}")"
[[ ! -e "${REL}" ]] || die "Release ${ID} already exists"
snapshot_release "${REL}"
{
  echo "id=${ID}"
  echo "git_sha=$(git -C "${LW_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo nogit)"
  echo "created_at=$(timestamp)"
  echo "operator=${SUDO_USER:-${USER:-unknown}}"
} >"${REL}/meta"
info "Release ${ID} snapshotted at ${REL}"

mark_failed() {
  echo "$1" >"${REL}/FAILED"
  meta_set "${REL}" status failed
}

PREFLIGHT_ARGS=(--release-dir "${REL}")
[[ -n "${SKIP}" ]] && PREFLIGHT_ARGS+=(--skip "${SKIP}")
if ! bash "${LW_REPO_ROOT}/scripts/deploy/preflight.sh" "${PREFLIGHT_ARGS[@]}"; then
  mark_failed preflight
  die "Preflight failed; nothing was changed"
fi

PREV="$(current_release_id)"
BACKUP=""
if [[ -n "${PREV}" ]]; then
  echo "${PREV}" >"${REL}/previous"
  BACKUP="$(bash "${LW_REPO_ROOT}/scripts/ops/backup.sh" --out "${LW_BACKUPS_DIR}/${ID}-pre")" || {
    mark_failed backup
    die "Pre-deploy backup failed; nothing was changed"
  }
  meta_set "${REL}" pre_deploy_backup "${BACKUP}"
fi

# Registries time out on multi-GB layers; pulling is idempotent, so retry.
: "${LW_PULL_RETRIES:=3}" "${LW_PULL_RETRY_DELAY:=20}"
for attempt in $(seq 1 "${LW_PULL_RETRIES}"); do
  stack_compose "${REL}" pull --quiet && break
  if [[ "${attempt}" -eq "${LW_PULL_RETRIES}" ]]; then
    mark_failed pull
    die "Image pull failed ${attempt} times; the running release ${PREV:-<none>} is untouched"
  fi
  warn "Image pull failed (attempt ${attempt}/${LW_PULL_RETRIES}); retrying in $((LW_PULL_RETRY_DELAY * attempt))s"
  sleep $((LW_PULL_RETRY_DELAY * attempt))
done

on_failure() {
  local stage=$1
  mark_failed "${stage}"
  fail "Release ${ID} failed at ${stage}"
  stack_compose "${REL}" ps >&2 || true
  if [[ -z "${PREV}" ]]; then
    die "No previous release to roll back to. Inspect: docker compose -p ${LW_PROJECT} logs"
  fi
  if [[ "${AUTO_ROLLBACK}" != true ]]; then
    die "Auto-rollback disabled. Roll back with: scripts/deploy/rollback.sh --to ${PREV} --restore-backup ${BACKUP} --yes"
  fi
  local restore=(--no-restore)
  if stateful_images_differ "${REL}" "$(release_dir "${PREV}")"; then
    warn "Stateful images changed: restoring pre-deploy backup ${BACKUP} (writes since the backup are lost)"
    restore=(--restore-backup "${BACKUP}")
  fi
  if bash "${LW_REPO_ROOT}/scripts/deploy/rollback.sh" --to "${PREV}" "${restore[@]}" --yes; then
    die "Deploy of ${ID} failed; rolled back to ${PREV}"
  fi
  die "Deploy of ${ID} failed AND rollback to ${PREV} failed: MANUAL INTERVENTION REQUIRED (docs/operations/RUNBOOK.md)"
}

info "Starting release ${ID} (waiting up to ${LW_WAIT_TIMEOUT}s for health)"
stack_compose "${REL}" up -d --wait --wait-timeout "${LW_WAIT_TIMEOUT}" --remove-orphans || on_failure up
bash "${LW_REPO_ROOT}/scripts/deploy/smoke-test.sh" --release-dir "${REL}" || on_failure smoke-test

set_current_release "${ID}"
meta_set "${REL}" status deployed
meta_set "${REL}" deployed_at "$(timestamp)"
pass "Release ${ID} is live (previous: ${PREV:-none})"
