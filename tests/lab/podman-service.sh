#!/usr/bin/env bash
# A dedicated, rootless Podman API service for the lab, fully separate from the
# user's normal Podman: own image/volume/network storage under LAB_DIR, own
# runroot, tmpdir and socket. Starting or removing it never touches existing
# containers or images. No root needed.
#   podman-service.sh start | stop | status | env
set -euo pipefail

LAB_DIR="${LAB_DIR:-/srv/lifewatch-lab}"
RUN="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR not set (log in as a normal user)}/lwlab"
SOCK="${RUN}/podman.sock"
PIDFILE="${RUN}/service.pid"
PODMAN=(podman --root "${LAB_DIR}/containers/storage" --runroot "${RUN}/runroot" --tmpdir "${RUN}/tmp")

running() { [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; }

case "${1:-}" in
  start)
    [[ -d "${LAB_DIR}" && -w "${LAB_DIR}" ]] || {
      echo "LAB_DIR ${LAB_DIR} must exist and be writable: sudo install -d -o $(id -un) -g $(id -gn) ${LAB_DIR}" >&2
      exit 1
    }
    mkdir -p "${RUN}" "${LAB_DIR}/containers/storage"
    if running; then echo "already running: unix://${SOCK}" >&2; exit 0; fi
    # Image layers are staged in TMPDIR while pulling (the vLLM image has
    # multi-GB layers). XDG_RUNTIME_DIR is a small RAM disk: stage on LAB_DIR.
    mkdir -p "${LAB_DIR}/tmp"
    TMPDIR="${LAB_DIR}/tmp" nohup "${PODMAN[@]}" system service --time=0 "unix://${SOCK}" >"${RUN}/service.log" 2>&1 &
    echo $! >"${PIDFILE}"
    for _ in $(seq 1 50); do [[ -S "${SOCK}" ]] && break; sleep 0.2; done
    [[ -S "${SOCK}" ]] || { echo "podman service did not start, see ${RUN}/service.log" >&2; exit 1; }
    echo "started: export DOCKER_HOST=unix://${SOCK}" >&2
    ;;
  stop)
    if running; then kill "$(cat "${PIDFILE}")"; fi
    rm -f "${PIDFILE}" "${SOCK}"
    ;;
  status)
    if running; then echo "running unix://${SOCK}"; else
      echo stopped
      exit 1
    fi
    ;;
  env) echo "export DOCKER_HOST=unix://${SOCK}" ;;
  *) echo "Usage: $0 start|stop|status|env" >&2; exit 2 ;;
esac
