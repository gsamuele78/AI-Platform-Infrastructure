#!/usr/bin/env bash
# Install systemd timers for unattended operations (run once per host, as root):
#   lifewatch-backup.timer       daily 02:30 (+ up to 15 min), state -> BACKUP_DIR
#   lifewatch-cert-renew.timer   twice daily, only with --with-cert-renew
#                                (Let's Encrypt phase; certbot renews at < 30 days)
# Note: the backup stops Open WebUI for the few seconds the SQLite copy takes.
#   install-timers.sh [--with-cert-renew]
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

: "${LW_SYSTEMD_DIR:=/etc/systemd/system}"
CERT=false
case "${1:-}" in
  --with-cert-renew) CERT=true ;;
  "") ;;
  *) die "Usage: $0 [--with-cert-renew]" ;;
esac
require_root

unit() { # unit NAME DESCRIPTION SCRIPT_AND_ARGS ON_CALENDAR RANDOM_DELAY
  cat >"${LW_SYSTEMD_DIR}/$1.service" <<EOF
[Unit]
Description=$2
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${LW_REPO_ROOT}/$3
Nice=10
EOF
  cat >"${LW_SYSTEMD_DIR}/$1.timer" <<EOF
[Unit]
Description=$2 (timer)

[Timer]
OnCalendar=$4
RandomizedDelaySec=$5
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

mkdir -p "${LW_SYSTEMD_DIR}"
unit lifewatch-backup "LifeWatch platform backup" "scripts/ops/backup.sh" "*-*-* 02:30:00" 15min
[[ "${CERT}" == true ]] &&
  unit lifewatch-cert-renew "LifeWatch Let's Encrypt renewal" "scripts/ops/tls-letsencrypt.sh --renew" "*-*-* 03,15:17:00" 1h

systemctl daemon-reload
systemctl enable --now lifewatch-backup.timer
[[ "${CERT}" == true ]] && systemctl enable --now lifewatch-cert-renew.timer
pass "Timers installed in ${LW_SYSTEMD_DIR} (systemctl list-timers 'lifewatch-*')"
