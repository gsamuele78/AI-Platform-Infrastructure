#!/usr/bin/env bats
# TLS lifecycle: phase 1 self-signed (private lab CA), phase 2 Let's Encrypt
# via certbot webroot, renewal timers. Real openssl; certbot is emulated.

load ../helpers/common
load ../helpers/stack

SELF="${BATS_TEST_DIRNAME}/../../scripts/ops/tls-selfsigned.sh"
LE="${BATS_TEST_DIRNAME}/../../scripts/ops/tls-letsencrypt.sh"
TIMERS="${BATS_TEST_DIRNAME}/../../scripts/ops/install-timers.sh"
HOST=ai.lifewatch.test

setup() {
  setup_sandbox
  load_stack_fixture
}

san_of() { openssl x509 -in "$1" -noout -ext subjectAltName; }
fp_of() { openssl x509 -in "$1" -noout -fingerprint -sha256; }

# ---- self-signed ----------------------------------------------------------------
@test "self-signed: leaf for PUBLIC_HOSTNAME, signed by a private CA, private key 0600" {
  [[ "$(cat "${TLS_DIR}/live/mode")" == self-signed ]]
  san_of "${TLS_DIR}/live/fullchain.pem" | grep -q "DNS:${HOST}"
  openssl verify -CAfile "${TLS_DIR}/live/ca.pem" "${TLS_DIR}/live/fullchain.pem"
  [[ "$(stat -c %a "${TLS_DIR}/live/privkey.pem")" == 600 ]]
  [[ "$(stat -c %a "${TLS_DIR}/ca")" == 700 ]]
  [[ "$(openssl x509 -in "${TLS_DIR}/live/fullchain.pem" -noout -ext basicConstraints 2>/dev/null)" != *CA:TRUE* ]]
}

@test "self-signed: re-running renews the leaf but keeps the CA users already trust" {
  local ca leaf
  ca="$(fp_of "${TLS_DIR}/live/ca.pem")"
  leaf="$(fp_of "${TLS_DIR}/live/fullchain.pem")"
  run bash "${SELF}"
  assert_status 0
  [[ "$(fp_of "${TLS_DIR}/live/ca.pem")" == "${ca}" ]]
  [[ "$(fp_of "${TLS_DIR}/live/fullchain.pem")" != "${leaf}" ]]
}

@test "self-signed: TLS_EXTRA_SANS adds names and IPs" {
  echo "TLS_EXTRA_SANS=IP:192.0.2.10,DNS:ai.lab" >>"${LW_ENV_FILE}"
  run bash "${SELF}"
  assert_status 0
  san_of "${TLS_DIR}/live/fullchain.pem" | grep -q "IP Address:192.0.2.10"
  san_of "${TLS_DIR}/live/fullchain.pem" | grep -q "DNS:ai.lab"
}

@test "self-signed: validates nginx config then reloads the running ingress" {
  run bash "${SELF}"
  assert_status 0
  called docker "exec cid-ingress nginx -t"
  called docker "exec cid-ingress nginx -s reload"
}

@test "self-signed: refuses to replace an active Let's Encrypt certificate without --force" {
  echo letsencrypt >"${TLS_DIR}/live/mode"
  run bash "${SELF}"
  assert_failure
  assert_output_contains "--force"
  run bash "${SELF}" --force
  assert_status 0
}

@test "self-signed: rejects an invalid hostname" {
  sed -i 's/^PUBLIC_HOSTNAME=.*/PUBLIC_HOSTNAME=bad_host;rm/' "${LW_ENV_FILE}"
  run bash "${SELF}"
  assert_failure
  assert_output_contains "PUBLIC_HOSTNAME"
}

# ---- Let's Encrypt ----------------------------------------------------------------
# Fake certbot: on certonly/renew, writes a cert for $LE_ISSUE_FOR (default the
# public hostname) into the certbot config dir, like the real one would.
fake_certbot() {
  cat >"${SANDBOX}/certbot.sh" <<EOF
#!/usr/bin/env bash
[[ " \$* " == *" renew "* && ! -f "${SANDBOX}/renew-issues" ]] && exit 0
d="${TLS_DIR}/letsencrypt/live/${HOST}"
mkdir -p "\$d"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 90 \\
  -subj "/CN=\${LE_ISSUE_FOR:-${HOST}}" -addext "subjectAltName=DNS:\${LE_ISSUE_FOR:-${HOST}}" \\
  -keyout "\$d/privkey.pem" -out "\$d/fullchain.pem" 2>/dev/null
EOF
  chmod +x "${SANDBOX}/certbot.sh"
}

deployed() {
  bash "${REPO_ROOT}/scripts/deploy/deploy.sh" >/dev/null 2>&1
  : >"${STUB_LOG}"
}

@test "letsencrypt: requires a deployed release with the ingress running" {
  fake_certbot
  run bash "${LE}" --email ops@lifewatch.test
  assert_failure
  assert_output_contains "deploy"
}

@test "letsencrypt: requires --email for issuance" {
  fake_certbot
  deployed
  run bash "${LE}"
  assert_failure
  assert_output_contains "--email"
}

@test "letsencrypt: issues via certbot webroot, installs the cert and reloads nginx" {
  fake_certbot
  deployed
  run bash "${LE}" --email ops@lifewatch.test --staging
  assert_status 0
  called docker "compose .* run --rm certbot certonly --webroot -w /var/www/acme -d ${HOST} .*--email ops@lifewatch.test .*--staging"
  [[ "$(cat "${TLS_DIR}/live/mode")" == letsencrypt ]]
  [[ ! -e "${TLS_DIR}/live/ca.pem" ]]
  cmp "${TLS_DIR}/live/fullchain.pem" "${TLS_DIR}/letsencrypt/live/${HOST}/fullchain.pem"
  [[ "$(stat -c %a "${TLS_DIR}/live/privkey.pem")" == 600 ]]
  called docker "exec cid-ingress nginx -s reload"
}

@test "letsencrypt: a failed issuance leaves the current certificate in place" {
  fake_certbot
  deployed
  cp "${TLS_DIR}/live/fullchain.pem" "${SANDBOX}/before.pem"
  echo 1 >"${SANDBOX}/fail.certbot"
  run bash "${LE}" --email ops@lifewatch.test
  assert_failure
  cmp "${TLS_DIR}/live/fullchain.pem" "${SANDBOX}/before.pem"
  refute called docker "nginx -s reload"
}

@test "letsencrypt: refuses to install a certificate that does not cover PUBLIC_HOSTNAME" {
  fake_certbot
  deployed
  export LE_ISSUE_FOR=wrong.example
  cp "${TLS_DIR}/live/fullchain.pem" "${SANDBOX}/before.pem"
  run bash "${LE}" --email ops@lifewatch.test
  assert_failure
  cmp "${TLS_DIR}/live/fullchain.pem" "${SANDBOX}/before.pem"
}

@test "letsencrypt: --renew without a new certificate does not reload nginx" {
  fake_certbot
  deployed
  bash "${LE}" --email ops@lifewatch.test 2>/dev/null
  : >"${STUB_LOG}"
  run bash "${LE}" --renew
  assert_status 0
  called docker "run --rm certbot renew"
  refute called docker "nginx -s reload"
}

@test "letsencrypt: --renew installs and reloads when certbot renewed" {
  fake_certbot
  deployed
  bash "${LE}" --email ops@lifewatch.test 2>/dev/null
  touch "${SANDBOX}/renew-issues"
  : >"${STUB_LOG}"
  run bash "${LE}" --renew
  assert_status 0
  called docker "exec cid-ingress nginx -s reload"
}

# ---- timers ---------------------------------------------------------------------
@test "install-timers: daily backup timer, cert renewal only on request" {
  as_root
  stub systemctl ''
  export LW_SYSTEMD_DIR="${SANDBOX}/systemd"
  run bash "${TIMERS}"
  assert_status 0
  grep -q "ExecStart=/usr/bin/env bash ${REPO_ROOT}/scripts/ops/backup.sh" "${LW_SYSTEMD_DIR}/lifewatch-backup.service"
  grep -q 'Persistent=true' "${LW_SYSTEMD_DIR}/lifewatch-backup.timer"
  [[ ! -e "${LW_SYSTEMD_DIR}/lifewatch-cert-renew.timer" ]]
  called systemctl "daemon-reload"
  called systemctl "enable --now lifewatch-backup.timer"
  run bash "${TIMERS}" --with-cert-renew
  assert_status 0
  grep -q "tls-letsencrypt.sh --renew" "${LW_SYSTEMD_DIR}/lifewatch-cert-renew.service"
  called systemctl "enable --now lifewatch-cert-renew.timer"
}

@test "install-timers: refuses non-root" {
  as_user
  run bash "${TIMERS}"
  assert_failure
}
