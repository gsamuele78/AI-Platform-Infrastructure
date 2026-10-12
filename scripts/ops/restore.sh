#!/usr/bin/env bash
# Restore platform state from a backup.sh directory. DESTRUCTIVE: replaces the
# LiteLLM database and the Open WebUI volume. Leaves gateway and UI STOPPED;
# the caller (rollback.sh, or the operator) starts the matching release.
#   restore.sh --from DIR [--yes]
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      FROM=$2
      shift 2
      ;;
    --yes)
      export LW_ASSUME_YES=1
      shift
      ;;
    *) die "Usage: $0 --from DIR [--yes]" ;;
  esac
done
[[ -d "${FROM}" ]] || die "Backup directory '${FROM}' not found"
FROM="$(cd "${FROM}" && pwd)"
(cd "${FROM}" && sha256sum --quiet -c SHA256SUMS) || die "Checksum verification failed for ${FROM}; refusing to restore"
pass "Backup checksums verified"

PG="$(container_id postgres)"
[[ -n "${PG}" ]] || die "postgres must be running to restore (docker compose up -d postgres)"

confirm "This REPLACES the LiteLLM database and Open WebUI data with ${FROM}." || die "Aborted by operator"

stop_writers
info "Recreating database"
# shellcheck disable=SC2016 # expanded inside the container, from its own env
docker exec "${PG}" sh -c 'dropdb -U "$POSTGRES_USER" --if-exists --force "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
# shellcheck disable=SC2016
docker exec -i "${PG}" sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' <"${FROM}/litellm.pgdump"
pass "Database restored"

TOOL_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${PG}")"
docker run --rm --network none \
  -v "${LW_PROJECT}_openwebui_data:/data" -v "${FROM}:/backup:ro" \
  "${TOOL_IMAGE}" sh -c 'find /data -mindepth 1 -delete && tar -C /data -xzf /backup/openwebui_data.tgz'
pass "Open WebUI data restored. Start the matching release next (scripts/deploy/rollback.sh)."
