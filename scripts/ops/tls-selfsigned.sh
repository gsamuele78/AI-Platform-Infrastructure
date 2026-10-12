#!/usr/bin/env bash
# TLS phase 1: certificate from a private lab CA.
#   tls-selfsigned.sh [--days 397] [--force]
# The CA (TLS_DIR/ca) is created once and reused, so clients import
# TLS_DIR/live/ca.pem a single time; re-running renews only the server cert.
# Refuses to replace an active Let's Encrypt certificate unless --force.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"
# shellcheck source=scripts/lib/tls.sh
source "${LW_REPO_ROOT}/scripts/lib/tls.sh"

DAYS=397 # browsers reject server certificates valid for more than 398 days
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      DAYS=$2
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    *) die "Usage: $0 [--days N] [--force]" ;;
  esac
done
[[ "${DAYS}" =~ ^[1-9][0-9]*$ && "${DAYS}" -le 397 ]] || die "--days must be 1-397"

HOST="$(tls_hostname)"
DIR="$(tls_dir)"
valid_hostname "${HOST}" || die "PUBLIC_HOSTNAME '${HOST}' is not a valid DNS name"
[[ -n "${DIR}" ]] || die "TLS_DIR is not set in ${LW_ENV_FILE}"
EXTRA="$(env_value "${LW_ENV_FILE}" TLS_EXTRA_SANS)"
[[ -z "${EXTRA}" || "${EXTRA}" =~ ^(IP|DNS):[A-Za-z0-9.:-]+(,(IP|DNS):[A-Za-z0-9.:-]+)*$ ]] ||
  die "TLS_EXTRA_SANS must look like IP:10.0.0.5,DNS:ai.lan"

if [[ "$(cat "${DIR}/live/mode" 2>/dev/null)" == letsencrypt && "${FORCE}" != true ]]; then
  die "A Let's Encrypt certificate is active; pass --force to replace it with a self-signed one"
fi

mkdir -p "${DIR}/ca" "${DIR}/live" "${DIR}/acme-webroot" "${DIR}/letsencrypt"
chmod 0700 "${DIR}" "${DIR}/ca" "${DIR}/live"
chmod 0755 "${DIR}/acme-webroot" "${DIR}/letsencrypt"

if [[ ! -f "${DIR}/ca/ca.pem" ]]; then
  info "Creating lab CA in ${DIR}/ca (10 years)"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 3650 \
    -subj "/O=LifeWatch ERIC/CN=LifeWatch AI Platform Lab CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${DIR}/ca/ca.key" -out "${DIR}/ca/ca.pem" 2>/dev/null
  chmod 600 "${DIR}/ca/ca.key"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SAN="DNS:${HOST}${EXTRA:+,${EXTRA}}"
cat >"${WORK}/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${WORK}/key.pem" 2>/dev/null
openssl req -new -key "${WORK}/key.pem" -subj "/CN=${HOST}" -out "${WORK}/csr.pem"
openssl x509 -req -in "${WORK}/csr.pem" -CA "${DIR}/ca/ca.pem" -CAkey "${DIR}/ca/ca.key" \
  -set_serial "0x$(openssl rand -hex 16)" -days "${DAYS}" -sha256 \
  -extfile "${WORK}/ext.cnf" -out "${WORK}/leaf.pem" 2>/dev/null
cat "${WORK}/leaf.pem" "${DIR}/ca/ca.pem" >"${WORK}/fullchain.pem"

install_live "${DIR}" "${WORK}/fullchain.pem" "${WORK}/key.pem" self-signed "${DIR}/ca/ca.pem"
pass "Self-signed certificate for ${SAN} installed (valid ${DAYS} days)"
info "Clients must trust ${DIR}/live/ca.pem ($(openssl x509 -in "${DIR}/ca/ca.pem" -noout -fingerprint -sha256))"
reload_ingress
