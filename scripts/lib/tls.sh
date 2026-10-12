#!/usr/bin/env bash
# TLS helpers for the ingress certificate. Source after common.sh and stack.sh.
# Layout of TLS_DIR:
#   live/          what nginx serves: fullchain.pem, privkey.pem, mode, [ca.pem]
#   ca/            private lab CA (self-signed phase only)
#   letsencrypt/   certbot config dir (account key, archive, renewal conf)
#   acme-webroot/  HTTP-01 challenge files, served by nginx on port 80

[[ -n "${_LW_TLS_SH:-}" ]] && return 0
_LW_TLS_SH=1

tls_dir() { env_value "${LW_ENV_FILE}" TLS_DIR; }
tls_hostname() { env_value "${LW_ENV_FILE}" PUBLIC_HOSTNAME; }

valid_hostname() {
  [[ "${#1}" -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

cert_covers() { openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null | grep -q 'does match'; }

key_matches() {
  [[ "$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl sha256)" == \
    "$(openssl pkey -in "$2" -pubout 2>/dev/null | openssl sha256)" ]]
}

# cert_valid_for CERT SECONDS: true if CERT does not expire within SECONDS.
cert_valid_for() { openssl x509 -in "$1" -noout -checkend "$2" >/dev/null 2>&1; }

# install_live DIR CERT KEY MODE [CA]: validate, then atomically swap the
# served certificate. Nothing is replaced unless every check passes.
install_live() {
  local dir=$1 cert=$2 key=$3 mode=$4 ca=${5:-} host live tmp
  host="$(tls_hostname)"
  live="${dir}/live"
  cert_covers "${cert}" "${host}" || die "Certificate ${cert} does not cover ${host}; not installed"
  key_matches "${cert}" "${key}" || die "Private key does not match ${cert}; not installed"
  cert_valid_for "${cert}" 0 || die "Certificate ${cert} is already expired; not installed"
  mkdir -p "${live}" && chmod 0700 "${live}"
  tmp="$(mktemp -d "${live}/.install.XXXXXX")"
  cp "${cert}" "${tmp}/fullchain.pem"
  install -m 0600 "${key}" "${tmp}/privkey.pem"
  echo "${mode}" >"${tmp}/mode"
  [[ -n "${ca}" ]] && cp "${ca}" "${tmp}/ca.pem"
  mv -f "${tmp}/fullchain.pem" "${tmp}/privkey.pem" "${tmp}/mode" "${live}/"
  if [[ -n "${ca}" ]]; then mv -f "${tmp}/ca.pem" "${live}/ca.pem"; else rm -f "${live}/ca.pem"; fi
  rmdir "${tmp}"
}

# Validate the nginx configuration with the new files, then reload gracefully.
reload_ingress() {
  local cid
  cid="$(container_id ingress)"
  if [[ -z "${cid}" ]]; then
    info "Ingress not running; the new certificate is used on next start"
    return 0
  fi
  docker exec "${cid}" nginx -t >/dev/null 2>&1 || die "nginx rejected the configuration; certificate files are in place but nginx was NOT reloaded"
  docker exec "${cid}" nginx -s reload >/dev/null
  pass "Ingress reloaded"
}
