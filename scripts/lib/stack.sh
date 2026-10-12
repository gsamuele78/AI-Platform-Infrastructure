#!/usr/bin/env bash
# Stack (guest VM) helpers shared by scripts/deploy and scripts/ops.
# A *release* is an immutable directory under $LW_STATE_DIR/releases holding
# the exact compose.yaml, release.env (a copy of the GPU profile, ADR-012) and
# configs/ that were deployed.
# Secrets are never copied into releases; they always come from $LW_ENV_FILE.

[[ -n "${_LW_STACK_SH:-}" ]] && return 0
_LW_STACK_SH=1

: "${LW_PROJECT:=lifewatch}"
: "${LW_STATE_DIR:=/var/lib/lifewatch}"
: "${LW_ENV_FILE:=${LW_REPO_ROOT}/.env}"
: "${LW_GATEWAY_URL:=http://127.0.0.1:4000}"
: "${LW_WEBUI_HEALTH_URL:=http://127.0.0.1:8080/health}"
# First start of vLLM loads ~75 GB and captures CUDA graphs: be generous.
: "${LW_WAIT_TIMEOUT:=1800}"
# Space-separated extra compose files (relative to the repo) layered on top of
# compose.yaml, e.g. a site-specific ingress or the CI fake backend.
: "${LW_COMPOSE_OVERRIDES:=}"

# shellcheck source=scripts/lib/profile.sh
source "${LW_REPO_ROOT}/scripts/lib/profile.sh"

LW_RELEASES_DIR="${LW_STATE_DIR}/releases"
# Services whose images own persistent schema (DB migrations, SQLite).
LW_STATEFUL_SERVICES=(litellm-gateway open-webui postgres)

# stack_compose RELEASE_DIR ARGS...: docker compose bound to one release.
stack_compose() {
  local dir=$1 f files=()
  shift
  while IFS= read -r f; do
    [[ -n "${f}" ]] && files+=(-f "${dir}/${f}")
  done <"${dir}/compose-files"
  docker compose -p "${LW_PROJECT}" --project-directory "${dir}" "${files[@]}" \
    --env-file "${dir}/release.env" --env-file "${LW_ENV_FILE}" "$@"
}

# env_value FILE KEY: value of KEY=... in a dotenv file (not sourced).
env_value() {
  local v
  v="$(grep -E "^$2=" "$1" | tail -1)" || return 0
  v="${v#*=}"
  v="${v%\"}"
  v="${v#\"}"
  printf '%s\n' "${v}"
}

container_id() {
  docker ps -q --filter "label=com.docker.compose.project=${LW_PROJECT}" \
    --filter "label=com.docker.compose.service=$1"
}

release_dir() { printf '%s/%s\n' "${LW_RELEASES_DIR}" "$1"; }

# snapshot_release DEST: copy the deployable files of the working tree into DEST.
snapshot_release() {
  local dest=$1 f profile
  profile="$(release_env_file)" || return 1
  mkdir -p "${dest}"
  cp "${LW_REPO_ROOT}/compose.yaml" "${dest}/compose.yaml"
  cp "${profile}" "${dest}/release.env"
  cp -R "${LW_REPO_ROOT}/configs" "${dest}/configs"
  echo compose.yaml >"${dest}/compose-files"
  for f in ${LW_COMPOSE_OVERRIDES}; do
    mkdir -p "${dest}/$(dirname "${f}")"
    cp -R "${LW_REPO_ROOT}/$(dirname "${f}")/." "${dest}/$(dirname "${f}")/"
    echo "${f}" >>"${dest}/compose-files"
  done
}

# active_release_env: the profile of the deployed release, or (before the first
# deploy) the one this machine would deploy.
active_release_env() {
  local cur
  cur="$(current_release_id)"
  if [[ -n "${cur}" && -f "$(release_dir "${cur}")/release.env" ]]; then
    printf '%s\n' "$(release_dir "${cur}")/release.env"
  else
    release_env_file
  fi
}

current_release_id() {
  [[ -L "${LW_RELEASES_DIR}/current" ]] || return 0
  basename "$(readlink -f "${LW_RELEASES_DIR}/current")"
}

set_current_release() {
  ln -sfn "$1" "${LW_RELEASES_DIR}/current.tmp"
  mv -Tf "${LW_RELEASES_DIR}/current.tmp" "${LW_RELEASES_DIR}/current"
}

meta_set() { echo "$2=$3" >>"$1/meta"; }

# release_images DIR: "service=image" lines for the stateful services.
release_images() {
  local json s
  json="$(stack_compose "$1" config --format json)" || return 1
  for s in "${LW_STATEFUL_SERVICES[@]}"; do
    printf '%s=%s\n' "${s}" "$(jq -r --arg s "${s}" '.services[$s].image // ""' <<<"${json}")"
  done
}

# stateful_images_differ DIR_A DIR_B: true if moving between the two releases
# can involve a schema migration, i.e. a data restore is needed to go back.
stateful_images_differ() {
  [[ "$(release_images "$1")" != "$(release_images "$2")" ]]
}

stop_writers() {
  local s cid
  for s in open-webui litellm-gateway; do
    cid="$(container_id "${s}")"
    [[ -n "${cid}" ]] && docker stop "${cid}" >/dev/null
  done
  return 0
}

# Backups live in BACKUP_DIR from .env: a dedicated mount (own disk now, an
# NFS/CIFS export later) rather than the VM root filesystem.
if [[ -z "${LW_BACKUPS_DIR:-}" ]]; then
  [[ -f "${LW_ENV_FILE}" ]] && LW_BACKUPS_DIR="$(env_value "${LW_ENV_FILE}" BACKUP_DIR)"
  LW_BACKUPS_DIR="${LW_BACKUPS_DIR:-${LW_STATE_DIR}/backups}"
fi

# backup_dir_checks: non-zero if BACKUP_DIR is unusable (missing, or not a mount
# while BACKUP_REQUIRE_MOUNT=true).
backup_dir_checks() {
  [[ -d "${LW_BACKUPS_DIR}" && -w "${LW_BACKUPS_DIR}" ]] || {
    fail "BACKUP_DIR ${LW_BACKUPS_DIR} does not exist or is not writable (mount the backup volume)"
    return 1
  }
  if mountpoint -q "${LW_BACKUPS_DIR}"; then
    pass "BACKUP_DIR ${LW_BACKUPS_DIR} is a dedicated mount"
  elif [[ "$(env_value "${LW_ENV_FILE}" BACKUP_REQUIRE_MOUNT)" == true ]]; then
    fail "BACKUP_DIR ${LW_BACKUPS_DIR} is not a mountpoint and BACKUP_REQUIRE_MOUNT=true"
    return 1
  else
    warn "BACKUP_DIR ${LW_BACKUPS_DIR} is not a dedicated mount: backups share the root disk"
  fi
}
