#!/usr/bin/env bats
# GPU profile selection (ADR-012): detection maps 1 or 2 L40S to a committed
# profile, refuses anything else, and preflight refuses unvalidated profiles.

load ../helpers/common
load ../helpers/stack

PREFLIGHT="${BATS_TEST_DIRNAME}/../../scripts/deploy/preflight.sh"

setup() {
  setup_sandbox
  load_stack_fixture
  stub_lspci
  : >"${SANDBOX}/lspci.out"
}

l40s() { local i; for ((i = 1; i <= $1; i++)); do echo "0${i}:00.0 0302: 10de:26b9 (rev a1)"; done >"${SANDBOX}/lspci.out"; }

# resolve: print release_env_file with no explicit file, as on a real VM.
resolve() {
  env -u LW_RELEASE_ENV "$@" bash -c 'source "$0/scripts/lib/common.sh"; source "$0/scripts/lib/profile.sh"; release_env_file' "${REPO_ROOT}"
}

@test "one L40S selects l40s-1, two select l40s-2" {
  l40s 1
  run resolve
  assert_status 0
  [[ "${output}" == */profiles/l40s-1.env ]]
  l40s 2
  run resolve
  assert_status 0
  [[ "${output}" == */profiles/l40s-2.env ]]
}

@test "unknown hardware is refused, never guessed" {
  run resolve
  assert_failure
  assert_output_contains "No profile for 0 GPU(s)"
  l40s 3
  run resolve
  assert_failure
  assert_output_contains "1 or 2 L40S"
}

@test "other GPU models do not count as an L40S" {
  echo '01:00.0 0302: 10de:2331 (rev a1)' >"${SANDBOX}/lspci.out" # H100 PCIe
  run resolve
  assert_failure
}

@test "LW_PROFILE overrides detection; an unknown name fails" {
  run resolve LW_PROFILE=l40s-1
  assert_status 0
  [[ "${output}" == */profiles/l40s-1.env ]]
  run resolve LW_PROFILE=a100-8
  assert_failure
  assert_output_contains "not found"
}

@test "an explicit LW_RELEASE_ENV wins over everything (lab, tests)" {
  run env LW_RELEASE_ENV=/some/file.env bash -c 'source "$0/scripts/lib/common.sh"; source "$0/scripts/lib/profile.sh"; release_env_file' "${REPO_ROOT}"
  assert_status 0
  [[ "${output}" == /some/file.env ]]
}

@test "preflight refuses a candidate profile unless explicitly allowed" {
  run env LW_ALLOW_UNVALIDATED=false bash "${PREFLIGHT}" --skip gpu,tls
  assert_failure
  assert_output_contains "not validated"
  run env LW_ALLOW_UNVALIDATED=true bash "${PREFLIGHT}" --skip gpu,tls
  assert_output_contains "LW_ALLOW_UNVALIDATED=true"
}

@test "preflight accepts a validated profile without the override" {
  sed -i 's/^PROFILE_STATUS=.*/PROFILE_STATUS=validated/' "${LW_RELEASE_ENV}"
  run env LW_ALLOW_UNVALIDATED=false bash "${PREFLIGHT}" --skip gpu,tls
  assert_output_contains "Profile l40s-2 (validated)"
  [[ "${output}" != *"not validated"* ]]
}

@test "preflight warns (does not fail) when the VM has more GPUs than the profile uses" {
  sed -i 's/^VLLM_GPU_COUNT=.*/VLLM_GPU_COUNT=1/' "${LW_RELEASE_ENV}"
  run bash "${PREFLIGHT}" --skip tls
  assert_output_contains "stay idle"
}
