#!/usr/bin/env bash
# TLS phase 2: Let's Encrypt via certbot (HTTP-01, webroot served by the ingress).
#   Issue:  tls-letsencrypt.sh --email ops@example.org [--staging]
#   Renew:  tls-letsencrypt.sh --renew          (systemd timer, see install-timers.sh)
# Requirements: PUBLIC_HOSTNAME resolves publicly to this host and port 80 is
# reachable from the internet. If it is not (internal-only service), use a
# DNS-01 certbot plugin or the institutional CA instead; see RUNBOOK §9.
# Testing only: --server URL --no-verify-ssl point certbot at an ACME test
# server such as Pebble (tests/integration/run.sh).
# The served certificate changes only after certbot succeeded AND the new
# certificate covers PUBLIC_HOSTNAME and matches its key.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/stack.sh
source "${LW_REPO_ROOT}/scripts/lib/stack.sh"
# shellcheck source=scripts/lib/tls.sh
source "${LW_REPO_ROOT}/scripts/lib/tls.sh"

EMAIL=""
RENEW=false
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      EMAIL=$2
      shift 2
      ;;
    --renew)
      RENEW=true
      shift
      ;;
    --staging)
      EXTRA+=(--staging)
      shift
      ;;
    --server)
      EXTRA+=(--server "$2")
      shift 2
      ;;
    --no-verify-ssl)
      EXTRA+=(--no-verify-ssl)
      shift
      ;;
    *) die "Usage: $0 --email ADDR [--staging] | --renew" ;;
  esac
done

CUR="$(current_release_id)"
[[ -n "${CUR}" ]] || die "No deployed release: deploy first (the ingress must serve the ACME webroot)"
REL="$(release_dir "${CUR}")"
[[ -n "$(container_id ingress)" ]] || die "Ingress is not running; deploy first"

HOST="$(tls_hostname)"
DIR="$(tls_dir)"
valid_hostname "${HOST}" || die "PUBLIC_HOSTNAME '${HOST}' is not a valid DNS name"
mkdir -p "${DIR}/letsencrypt" "${DIR}/acme-webroot"
chmod 0755 "${DIR}/letsencrypt" "${DIR}/acme-webroot"

certbot() { stack_compose "${REL}" --profile tools run --rm certbot "$@"; }

if [[ "${RENEW}" == true ]]; then
  certbot renew --non-interactive "${EXTRA[@]}" || die "certbot renew failed; current certificate unchanged"
else
  [[ "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "--email is required (expiry notices go there)"
  certbot certonly --webroot -w /var/www/acme -d "${HOST}" --email "${EMAIL}" \
    --agree-tos --non-interactive --keep-until-expiring --key-type ecdsa "${EXTRA[@]}" ||
    die "certbot failed; current certificate unchanged"
fi

SRC="${DIR}/letsencrypt/live/${HOST}"
[[ -f "${SRC}/fullchain.pem" ]] || die "certbot reported success but ${SRC}/fullchain.pem is missing"
if [[ "$(cat "${DIR}/live/mode" 2>/dev/null)" == letsencrypt ]] && cmp -s "${SRC}/fullchain.pem" "${DIR}/live/fullchain.pem"; then
  pass "Certificate unchanged; nothing to install"
  exit 0
fi
install_live "${DIR}" "${SRC}/fullchain.pem" "${SRC}/privkey.pem" letsencrypt
pass "Let's Encrypt certificate for ${HOST} installed (expires $(openssl x509 -in "${DIR}/live/fullchain.pem" -noout -enddate | cut -d= -f2))"
reload_ingress
