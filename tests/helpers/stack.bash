# shellcheck shell=bash disable=SC2016
# Fake single-node stack for deploy/rollback/backup tests.
# - docker: `compose ... config` runs the REAL docker client (client-side only),
#   everything else is emulated: running containers are files $SANDBOX/run/<svc>.
# - curl: emulates gateway, webui and ingress responses; $SANDBOX/curl.<case>
#   overrides a status code.
# - TLS: real certificates from scripts/ops/tls-selfsigned.sh (real openssl).
# - git: clean tree unless $SANDBOX/git.status has content.

REAL_DOCKER="$(command -v docker)"
export REAL_DOCKER

load_stack_fixture() {
  export LW_STATE_DIR="${SANDBOX}/state"
  export LW_ENV_FILE="${SANDBOX}/dot.env"
  export LW_RELEASE_ENV="${SANDBOX}/release.env"
  export LW_WAIT_TIMEOUT=30
  export STUB_MASTER_KEY="sk-test-master-0123456789abcdef0123456789"
  export SERVED_MODEL=lifewatch-chat
  export TLS_DIR="${SANDBOX}/tls" BACKUP_DIR="${SANDBOX}/backups"
  mkdir -p "${SANDBOX}/run" "${SANDBOX}/cache" "${BACKUP_DIR}"

  sed -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${STUB_MASTER_KEY}|" \
    -e 's|^OPENWEBUI_API_KEY=.*|OPENWEBUI_API_KEY=sk-test-webui-key-0123456789abcdef|' \
    -e 's|CHANGE_ME|0123456789abcdef0123456789abcdef|g' \
    -e "s|^TLS_DIR=.*|TLS_DIR=${TLS_DIR}|" -e "s|^BACKUP_DIR=.*|BACKUP_DIR=${BACKUP_DIR}|" \
    -e 's|^PUBLIC_HOSTNAME=.*|PUBLIC_HOSTNAME=ai.lifewatch.test|' \
    -e 's|^WEBUI_URL=.*|WEBUI_URL=https://ai.lifewatch.test|' \
    "${REPO_ROOT}/.env.example" >"${LW_ENV_FILE}"
  chmod 600 "${LW_ENV_FILE}"

  sed "s|^MODEL_CACHE_DIR=.*|MODEL_CACHE_DIR=${SANDBOX}/cache|" "${REPO_ROOT}/release.env" >"${LW_RELEASE_ENV}"
  local id rev
  id="$(grep '^MODEL_ID=' "${LW_RELEASE_ENV}" | cut -d= -f2)"
  rev="$(grep '^MODEL_REVISION=' "${LW_RELEASE_ENV}" | cut -d= -f2)"
  export MODEL_SNAPSHOT="${SANDBOX}/cache/hub/models--${id//\//--}/snapshots/${rev}"
  mkdir -p "${MODEL_SNAPSHOT}"
  touch "${MODEL_SNAPSHOT}/config.json"

  for s in postgres litellm-gateway open-webui vllm-backend ingress; do touch "${SANDBOX}/run/${s}"; done
  stub mountpoint 'exit 0'

  stub nvidia-smi 'printf "NVIDIA L40S\nNVIDIA L40S\n"'
  stub git '
case "$*" in
  *"status --porcelain"*) cat "$SANDBOX/git.status" 2>/dev/null ;;
  *"rev-parse --short HEAD"*) echo abc1234 ;;
  *"rev-parse HEAD"*) echo abc1234def5678 ;;
  *) exit 0 ;;
esac'
  stub docker "$(cat <<'EOF'
consume_failure() { # consume_failure NAME -> exit 1 if $SANDBOX/fail.NAME holds a count > 0
  local f="$SANDBOX/fail.$1" n
  [[ -f "$f" ]] || return 0
  n=$(cat "$f"); [[ "$n" -gt 0 ]] || return 0
  echo $((n - 1)) >"$f"; echo "simulated $1 failure" >&2; exit 1
}
svc_from_filters() { local a; for a in "$@"; do [[ "$a" == label=com.docker.compose.service=* ]] && echo "${a#*=*=}"; done; }
case "$1" in
  compose)
    if [[ " $* " == *" config "* ]]; then exec "$REAL_DOCKER" "$@"; fi
    [[ " $* " == *" pull "* ]] && consume_failure pull
    [[ " $* " == *" up "* ]] && { consume_failure up; for s in postgres litellm-gateway open-webui vllm-backend ingress; do touch "$SANDBOX/run/$s"; done; }
    if [[ " $* " == *" run "*certbot* ]]; then
      consume_failure certbot
      [[ -x "$SANDBOX/certbot.sh" ]] && "$SANDBOX/certbot.sh" "$@"
    fi
    exit 0 ;;
  ps)
    s=$(svc_from_filters "$@"); [[ -f "$SANDBOX/run/$s" ]] && echo "cid-$s"; exit 0 ;;
  stop) rm -f "$SANDBOX/run/${2#cid-}"; exit 0 ;;
  start) touch "$SANDBOX/run/${2#cid-}"; exit 0 ;;
  inspect) echo "postgres:16-alpine@sha256:abc"; exit 0 ;;
  exec)
    case "$*" in
      *pg_dump*) consume_failure pg_dump; printf 'PGDMP-fake-dump' ;;
      *"pg_restore --list"*|*"pg_restore -l"*) cat >/dev/null ;;
      *pg_restore*) cat >/dev/null ;;
    esac
    exit 0 ;;
  run)
    consume_failure tar
    for a in "$@"; do
      if [[ "$a" == *:/backup* ]]; then host=${a%%:/backup*}; fi
    done
    [[ " $* " == *czf* ]] && echo fake-tar >"$host/openwebui_data.tgz"
    exit 0 ;;
esac
exit 0
EOF
)"
  stub curl "$(cat <<'EOF'
out=/dev/null url="" auth="" method=GET
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H) [[ "$2" == Authorization:* ]] && auth=${2#Authorization: Bearer }; shift 2 ;;
    -X) method=$2; shift 2 ;;
    -d|--data) method=POST; shift 2 ;;
    -w|--max-time|-m|--resolve|--cacert) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
code() { local c=$1 body=${2:-}; [[ -f "$SANDBOX/curl.$3" ]] && c=$(cat "$SANDBOX/curl.$3"); printf '%s' "$body" >"$out"; printf '%s' "$c"; }
case "$url" in
  http://*/healthz) code 200 ok ingress_health ;;
  http://*:80/|http://127.0.0.1/) code 301 '' redirect ;;
  https://*:8443/key/generate) code 404 '' ingress_admin ;;
  https://*:8443/v1/chat/completions) [[ -z "$auth" ]] && code 401 '{}' ingress_unauth || code 200 '{}' ingress_unauth ;;
  https://*/health) code 200 '{"status":true}' ingress_ui ;;
  */health/liveliness) code 200 '"I am alive!"' gateway ;;
  */health) code 200 '{"status":true}' webui ;;
  */v1/models)
    if [[ "$auth" == "$STUB_MASTER_KEY" ]]; then code 200 "{\"data\":[{\"id\":\"$SERVED_MODEL\"}]}" models
    else code 401 '{"error":"auth"}' models; fi ;;
  */v1/chat/completions)
    if [[ -z "$auth" ]]; then code 401 '{"error":"no key"}' unauth
    elif [[ "$auth" != "$STUB_MASTER_KEY" ]]; then code 401 '{"error":"bad key"}' badkey
    else code 200 '{"choices":[{"message":{"content":"o"}}]}' inference; fi ;;
  */key/generate) code 200 '{"key":"sk-generated-virtual-key"}' keygen ;;
  *) printf '000'; exit 7 ;;
esac
EOF
)"
  bash "${REPO_ROOT}/scripts/ops/tls-selfsigned.sh" 2>/dev/null
  : >"${STUB_LOG}"
}

release_dirs() { find "${LW_STATE_DIR}/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort; }
current_release() { basename "$(readlink -f "${LW_STATE_DIR}/releases/current")"; }
