#!/usr/bin/env bats
# Guest-VM scripts: vm-check.sh (acceptance gate), fetch-model.sh (offline
# weight staging), bootstrap.sh (reproducible host packages), issue-key.sh.

load ../helpers/common
load ../helpers/stack

VMCHECK="${BATS_TEST_DIRNAME}/../../scripts/verify/vm-check.sh"
FETCH="${BATS_TEST_DIRNAME}/../../scripts/vm/fetch-model.sh"
BOOTSTRAP="${BATS_TEST_DIRNAME}/../../scripts/vm/bootstrap.sh"
ISSUE="${BATS_TEST_DIRNAME}/../../scripts/ops/issue-key.sh"

setup() {
  setup_sandbox
  load_stack_fixture
  stub nvidia-smi '
case "$*" in
  *memory.total*) printf "NVIDIA L40S, 46068\nNVIDIA L40S, 46068\n" ;;
  *topo*) echo "GPU0 GPU1: NS" ;;
  *) echo "nvidia-smi ok" ;;
esac'
  printf '01:00.0 0302: 10de:26b9 (rev a1)\n02:00.0 0302: 10de:26b9 (rev a1)\n' >"${SANDBOX}/lspci.out"
  stub_lspci
}

# ---- vm-check ------------------------------------------------------------------
@test "vm-check passes with two 48 GB L40S and a working container runtime" {
  run bash "${VMCHECK}"
  assert_status 0
  called docker "run --rm --gpus all nvidia/cuda:[^ ]+@sha256:"
}

@test "vm-check fails (not warns) when only one GPU is visible" {
  stub nvidia-smi 'case "$*" in *memory.total*) echo "NVIDIA L40S, 46068" ;; esac'
  run bash "${VMCHECK}"
  assert_failure
  assert_output_contains "expected 2"
}

@test "vm-check passes with one L40S passed through (profile l40s-1)" {
  echo '01:00.0 0302: 10de:26b9 (rev a1)' >"${SANDBOX}/lspci.out"
  stub nvidia-smi 'case "$*" in *memory.total*) echo "NVIDIA L40S, 46068" ;; *) echo ok ;; esac'
  run bash "${VMCHECK}"
  assert_status 0
  assert_output_contains "1 L40S on the PCI bus"
}

@test "vm-check fails when a passed-through card is not usable by the driver" {
  echo '01:00.0 0302: 10de:26b9 (rev a1)' >>"${SANDBOX}/lspci.out" # 3 on the bus
  run bash "${VMCHECK}"
  assert_failure
  assert_output_contains "1 or 2 L40S"
}

@test "vm-check fails when no L40S is on the PCI bus" {
  : >"${SANDBOX}/lspci.out"
  run bash "${VMCHECK}"
  assert_failure
  assert_output_contains "hostpci"
}

@test "vm-check fails when a GPU reports less memory than an L40S" {
  stub nvidia-smi 'case "$*" in *memory.total*) printf "NVIDIA L40S, 46068\nNVIDIA L4, 23034\n" ;; esac'
  run bash "${VMCHECK}"
  assert_failure
  assert_output_contains "23034"
}

@test "vm-check fails when containers cannot reach the GPUs" {
  stub docker 'exit 125'
  run bash "${VMCHECK}"
  assert_failure
}

@test "vm-check fails when nvidia-smi is missing" {
  rm "${STUB_BIN}/nvidia-smi"
  mkdir -p "${SANDBOX}/minbin"
  ln -s "$(command -v dirname)" "${SANDBOX}/minbin/dirname"
  run env PATH="${STUB_BIN}:${SANDBOX}/minbin" "$(command -v bash)" "${VMCHECK}"
  assert_failure
  assert_output_contains "nvidia-smi"
}

# ---- fetch-model ------------------------------------------------------------
@test "fetch-model downloads the pinned revision with the pinned vLLM image" {
  rm -rf "${MODEL_SNAPSHOT}"
  stub docker '
[[ "$1 $2" == "compose -p" || " $* " == *" config "* ]] && exec "$REAL_DOCKER" "$@"
[[ "$1" == run ]] && { mkdir -p "$MODEL_SNAPSHOT"; touch "$MODEL_SNAPSHOT/model.safetensors"; }
exit 0'
  run env LW_MIN_FREE_GB=0 bash "${FETCH}"
  assert_status 0
  called docker "run --rm .*--entrypoint hf .*vllm/vllm-openai:v0.31.0@sha256:"
  called docker "download Qwen/Qwen3.8-27B-FP8 --revision 017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"
  refute grep -q 'HF_TOKEN=' "${STUB_LOG}" # token passed by name, never on argv
}

@test "fetch-model honours the lab profile" {
  sed "s|^MODEL_CACHE_DIR=.*|MODEL_CACHE_DIR=${SANDBOX}/cache|" "${REPO_ROOT}/profiles/lab.env" >"${LW_RELEASE_ENV}"
  stub docker '[[ " $* " == *" config "* ]] && exec "$REAL_DOCKER" "$@"; [[ "$1" == run ]] && mkdir -p "$SANDBOX/cache/hub/models--Qwen--Qwen3.5-0.8B/snapshots/2fc06364715b967f1860aea9cf38778875588b17" && touch "$_/x"; exit 0'
  run env LW_MIN_FREE_GB=0 bash "${FETCH}"
  assert_status 0
  called docker "download Qwen/Qwen3.5-0.8B --revision 2fc06364715b967f1860aea9cf38778875588b17"
}

@test "fetch-model fails if the snapshot is still missing afterwards" {
  rm -rf "${MODEL_SNAPSHOT}"
  stub docker '[[ " $* " == *" config "* ]] && exec "$REAL_DOCKER" "$@"; exit 0'
  run env LW_MIN_FREE_GB=0 bash "${FETCH}"
  assert_failure
}

@test "fetch-model refuses when the cache volume lacks free space" {
  rm -rf "${MODEL_SNAPSHOT}"
  run env LW_MIN_FREE_GB=999999999 bash "${FETCH}"
  assert_failure
  assert_output_contains "free"
}

# ---- bootstrap ----------------------------------------------------------------
bootstrap_fixture() {
  export LW_OS_RELEASE="${SANDBOX}/os-release"
  export LW_APT_SOURCES_DIR="${SANDBOX}/apt/sources.list.d"
  export LW_KEYRINGS_DIR="${SANDBOX}/keyrings"
  export LW_DOCKER_DAEMON_JSON="${SANDBOX}/daemon.json"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"${LW_OS_RELEASE}"
  echo '{}' >"${LW_DOCKER_DAEMON_JSON}"
  for c in apt-get apt-mark ubuntu-drivers systemctl; do stub "${c}" ''; done
  stub gpg 'cat >/dev/null'
  stub dpkg 'echo amd64'
  stub dpkg-query 'printf "ii  nvidia-utils-580-server\nun  nvidia-kernel-common-580-server-580.178.04\n"'
  stub curl 'for a in "$@"; do [[ "$prev" == -o ]] && echo key >"$a"; prev=$a; done; echo key'
  stub nvidia-ctk ''
  as_root
}

@test "bootstrap refuses to run as non-root" {
  bootstrap_fixture
  as_user
  run bash "${BOOTSTRAP}"
  assert_failure
}

@test "bootstrap refuses anything but Ubuntu 24.04" {
  bootstrap_fixture
  printf 'ID=ubuntu\nVERSION_ID="22.04"\n' >"${LW_OS_RELEASE}"
  run bash "${BOOTSTRAP}"
  assert_failure
  assert_output_contains "24.04"
}

@test "bootstrap uses signed apt repositories, never curl | sh" {
  bootstrap_fixture
  run bash "${BOOTSTRAP}"
  assert_status 0
  refute grep -q get.docker.com "${STUB_LOG}"
  grep -q 'signed-by=' "${LW_APT_SOURCES_DIR}/docker.list"
  grep -q 'signed-by=' "${LW_APT_SOURCES_DIR}/nvidia-container-toolkit.list"
  called apt-get "install -y .*docker-ce .*nvidia-container-toolkit"
  called ubuntu-drivers "install --gpgpu nvidia:580-server" # >= 580 for the CUDA 13 vLLM image
}

@test "bootstrap holds runtime packages so unattended upgrades cannot restart dockerd" {
  bootstrap_fixture
  run bash "${BOOTSTRAP}"
  assert_status 0
  called apt-mark "hold .*docker-ce .*containerd.io .*nvidia-container-toolkit .*nvidia-utils-580-server"
  refute called apt-mark "nvidia-kernel-common" # not installed: apt-mark would fail
}

@test "bootstrap restarts docker only when the runtime config changed" {
  bootstrap_fixture
  run bash "${BOOTSTRAP}"
  assert_status 0
  refute called systemctl "restart docker"
  stub nvidia-ctk 'echo "{\"runtimes\":{\"nvidia\":{}}}" >"$LW_DOCKER_DAEMON_JSON"'
  run bash "${BOOTSTRAP}"
  assert_status 0
  called systemctl "restart docker"
}

# ---- issue-key ----------------------------------------------------------------
@test "issue-key creates a scoped key via the master key and prints only the key" {
  run bash -c "bash '${ISSUE}' --alias open-webui 2>/dev/null"
  assert_status 0
  [[ "${output}" == sk-generated-virtual-key ]]
  called curl "/key/generate"
}

@test "issue-key requires an alias" {
  run bash "${ISSUE}"
  assert_failure
}

@test "issue-key sets per-key rate, token and concurrency limits" {
  run bash -c "bash '${ISSUE}' --alias agent-x --rpm 60 --tpm 200000 --max-parallel 2 --max-budget 50 2>/dev/null"
  assert_status 0
  jq -e '.rpm_limit == 60 and .tpm_limit == 200000 and .max_parallel_requests == 2 and .max_budget == 50
    and .models == ["lifewatch-chat"] and .key_alias == "agent-x"' "${SANDBOX}/keygen.payload"
}

@test "issue-key rejects non-numeric limits before calling the gateway" {
  run bash "${ISSUE}" --alias a --rpm lots
  assert_failure
  run bash "${ISSUE}" --alias a --max-budget 'x;y'
  assert_failure
  not_called curl
}

