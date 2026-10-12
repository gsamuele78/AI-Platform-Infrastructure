#!/usr/bin/env bash
# Consistent backup of all platform state:
#   - LiteLLM Postgres (keys, budgets, spend/audit) via pg_dump -Fc, verified
#     with pg_restore --list;
#   - Open WebUI volume (SQLite + uploads), copied with Open WebUI STOPPED so the
#     SQLite file is consistent; it is restarted even if the copy fails.
#   - TLS_DIR (lab CA key, Let's Encrypt account), for disaster recovery only;
#     restore.sh does not touch certificates.
# Model weights are deliberately excluded (re-downloadable, ADR-007).
# Default destination: BACKUP_DIR from .env (a dedicated mount).
#   backup.sh [--out DIR] [--keep N]
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"

OUT=""
KEEP=14
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT=$2
      shift 2
      ;;
    --keep)
      KEEP=$2
      shift 2
      ;;
    *) die "Usage: $0 [--out DIR] [--keep N]" ;;
  esac
done
[[ "${KEEP}" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"
if [[ -z "${OUT}" ]]; then
  backup_dir_checks || die "No usable backup destination"
  OUT="${LW_BACKUPS_DIR}/$(timestamp)"
fi
[[ -d "$(dirname "${OUT}")" ]] || die "Parent of ${OUT} does not exist (is the backup volume mounted?)"

PG="$(container_id postgres)"
[[ -n "${PG}" ]] || die "postgres container is not running (project ${LW_PROJECT}); cannot back up"
[[ ! -e "${OUT}" ]] || die "${OUT} already exists"
mkdir -m 0700 "${OUT}"
info "Backing up to ${OUT}"

# shellcheck disable=SC2016 # expanded inside the container, from its own env
docker exec "${PG}" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' >"${OUT}/litellm.pgdump"
[[ -s "${OUT}/litellm.pgdump" ]] || die "pg_dump produced an empty file"
docker exec -i "${PG}" pg_restore --list <"${OUT}/litellm.pgdump" >/dev/null ||
  die "pg_dump output is not a readable archive"
pass "Postgres dump verified"

TOOL_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${PG}")"
WEBUI="$(container_id open-webui)"
restart_webui() { [[ -n "${WEBUI}" ]] && docker start "${WEBUI}" >/dev/null; }
if [[ -n "${WEBUI}" ]]; then
  docker stop "${WEBUI}" >/dev/null
  trap restart_webui EXIT
fi
docker run --rm --network none \
  -v "${LW_PROJECT}_openwebui_data:/data:ro" -v "${OUT}:/backup" \
  "${TOOL_IMAGE}" tar -C /data -czf /backup/openwebui_data.tgz .
restart_webui
trap - EXIT
pass "Open WebUI data archived"

FILES=(litellm.pgdump openwebui_data.tgz meta)
TLS_DIR_PATH="$(env_value "${LW_ENV_FILE}" TLS_DIR)"
if [[ -n "${TLS_DIR_PATH}" && -d "${TLS_DIR_PATH}" ]]; then
  tar -C "${TLS_DIR_PATH}" --exclude=./acme-webroot -czf "${OUT}/tls.tgz" .
  FILES+=(tls.tgz)
  pass "TLS material archived"
else
  warn "TLS_DIR not found; certificates and CA are not in this backup"
fi

{
  echo "created_at=$(timestamp)"
  echo "release=$(current_release_id)"
} >"${OUT}/meta"
(cd "${OUT}" && sha256sum "${FILES[@]}" >SHA256SUMS)
pass "Backup complete: ${OUT}"

# Retention: only directories that are complete backups (have SHA256SUMS).
if [[ "$(dirname "${OUT}")" == "${LW_BACKUPS_DIR}" ]]; then
  mapfile -t old < <(find "${LW_BACKUPS_DIR}" -mindepth 2 -maxdepth 2 -name SHA256SUMS -printf '%h\n' | sort | head -n "-${KEEP}")
  for d in "${old[@]}"; do
    info "Pruning old backup ${d}"
    rm -rf -- "${d}"
  done
fi
printf '%s\n' "${OUT}"
