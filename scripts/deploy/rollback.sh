#!/usr/bin/env bash
# Return the stack to an earlier release snapshot.
#   rollback.sh --previous | --to <release-id>  [--restore-backup DIR | --no-restore] [--yes]
#
# Data is the hard part of rollback: LiteLLM and Open WebUI migrate their
# schema forward on start, and old images cannot read a migrated schema. If the
# stateful images differ between the two releases you must choose explicitly:
#   --restore-backup DIR  restore the backup taken before the newer release
#                         (everything written since that backup is lost)
#   --no-restore          keep current data (only safe if no migration ran)
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

TARGET=""
RESTORE=""
NO_RESTORE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)
      TARGET=$2
      shift 2
      ;;
    --previous)
      CUR="$(current_release_id)"
      [[ -n "${CUR}" && -f "$(release_dir "${CUR}")/previous" ]] || die "Current release has no recorded previous release"
      TARGET="$(cat "$(release_dir "${CUR}")/previous")"
      shift
      ;;
    --restore-backup)
      RESTORE=$2
      shift 2
      ;;
    --no-restore)
      NO_RESTORE=true
      shift
      ;;
    --yes)
      export LW_ASSUME_YES=1
      shift
      ;;
    *) die "Usage: $0 --previous | --to <id> [--restore-backup DIR | --no-restore] [--yes]" ;;
  esac
done
[[ -n "${TARGET}" ]] || die "Specify --previous or --to <release-id>"
[[ "${TARGET}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid release id '${TARGET}'"
DIR="$(release_dir "${TARGET}")"
[[ -f "${DIR}/compose.yaml" && -f "${DIR}/compose-files" ]] || die "Release ${TARGET} not found under ${LW_RELEASES_DIR}"
[[ -z "${RESTORE}" || "${NO_RESTORE}" == false ]] || die "--restore-backup and --no-restore are mutually exclusive"

CUR="$(current_release_id)"
if [[ -z "${RESTORE}" && "${NO_RESTORE}" == false && -n "${CUR}" && "${CUR}" != "${TARGET}" ]]; then
  if stateful_images_differ "$(release_dir "${CUR}")" "${DIR}"; then
    hint="$(env_value "$(release_dir "${CUR}")/meta" pre_deploy_backup)"
    die "Stateful images differ between ${CUR} and ${TARGET}. Choose explicitly: --restore-backup ${hint:-<dir>} (loses writes since then) or --no-restore (only if no migration ran)."
  fi
fi

confirm "Roll back to release ${TARGET}?" || die "Aborted by operator"

if [[ -n "${RESTORE}" ]]; then
  # The failed release may have left Postgres stopped or recreated.
  stack_compose "${DIR}" up -d --wait --wait-timeout 300 postgres ||
    die "Postgres from release ${TARGET} did not start; cannot restore data. MANUAL INTERVENTION REQUIRED"
  bash "${LW_REPO_ROOT}/scripts/ops/restore.sh" --from "${RESTORE}" --yes
fi

info "Starting release ${TARGET}"
stack_compose "${DIR}" up -d --wait --wait-timeout "${LW_WAIT_TIMEOUT}" --remove-orphans ||
  die "Release ${TARGET} did not become healthy: MANUAL INTERVENTION REQUIRED (docs/operations/RUNBOOK.md)"
bash "${LW_REPO_ROOT}/scripts/deploy/smoke-test.sh" --release-dir "${DIR}" ||
  die "Release ${TARGET} is up but fails the smoke test: MANUAL INTERVENTION REQUIRED"

set_current_release "${TARGET}"
meta_set "${DIR}" rolled_back_to_at "$(timestamp)"
pass "Rolled back to ${TARGET}"
