#!/usr/bin/env bash
set -euo pipefail

# E2E Test Runner for home-bootstrap
# Runs all layer tests sequentially with structured pass/fail reporting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TESTS_DIR="${REPO_ROOT}/tests"

# Source .env if present
if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

PASS=0
FAIL=0
SKIP=0
RESULTS=()
START_TIME=$(date +%s)

run_test() {
    local name="$1"
    local script="$2"
    shift 2
    local args=("$@")

    printf "\n=== [TEST] %s ===\n" "${name}"
    local test_start
    test_start=$(date +%s)

    if [[ ! -x "${script}" ]]; then
        printf "  SKIP: %s not found or not executable\n" "${script}"
        SKIP=$((SKIP + 1))
        RESULTS+=("SKIP  ${name}")
        return 0
    fi

    if "${script}" "${args[@]+"${args[@]}"}"; then
        local test_end
        test_end=$(date +%s)
        local duration=$((test_end - test_start))
        printf "  PASS (%ds)\n" "${duration}"
        PASS=$((PASS + 1))
        RESULTS+=("PASS  ${name} (${duration}s)")
    else
        local test_end
        test_end=$(date +%s)
        local duration=$((test_end - test_start))
        printf "  FAIL (%ds)\n" "${duration}"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  ${name} (${duration}s)")
    fi
}

echo "=============================================="
echo "  home-bootstrap End-to-End Test Suite"
echo "  $(date -Iseconds)"
echo "=============================================="

# Layer 1: iLO (optional - requires HOST env var)
if [[ -n "${ILO_HOST:-}" ]]; then
    run_test "Layer 1: iLO Provisioning" "${TESTS_DIR}/e2e/test_ilo_provision.sh" "${ILO_HOST}"
else
    echo ""
    echo "=== [SKIP] Layer 1: iLO Provisioning (set ILO_HOST to enable) ==="
    SKIP=$((SKIP + 1))
    RESULTS+=("SKIP  Layer 1: iLO Provisioning (ILO_HOST not set)")
fi

# Layer 2: VM Provisioning
run_test "Layer 2: VM Provisioning" "${TESTS_DIR}/e2e/test_vm_provision.sh"

# Layer 3: k3s Cluster
run_test "Layer 3: k3s Cluster" "${TESTS_DIR}/k8s/smoke/test_cluster.sh"

# Layer 3b: Infrastructure Services
run_test "Layer 3b: Infrastructure Services" "${TESTS_DIR}/k8s/smoke/test_infra.sh"

# Layer 4: SDLC Health Checks
run_test "Layer 4: SDLC Service Health" "${TESTS_DIR}/k8s/smoke/test_sdlc_health.sh"

# Layer 4b: Observability
run_test "Layer 4b: Observability Stack" "${TESTS_DIR}/e2e/test_observability.sh"

# Layer 5: CI Pipeline (long-running, optional)
if [[ "${RUN_CI_TEST:-false}" == "true" ]]; then
    run_test "Layer 5: CI Pipeline Integration" "${TESTS_DIR}/e2e/test_ci_pipeline.sh"
else
    echo ""
    echo "=== [SKIP] Layer 5: CI Pipeline (set RUN_CI_TEST=true to enable) ==="
    SKIP=$((SKIP + 1))
    RESULTS+=("SKIP  Layer 5: CI Pipeline (RUN_CI_TEST not set)")
fi

# Summary
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "=============================================="
echo "  Test Results Summary"
echo "=============================================="
for result in "${RESULTS[@]}"; do
    echo "  ${result}"
done
echo ""
echo "  Total: $((PASS + FAIL + SKIP)) | Pass: ${PASS} | Fail: ${FAIL} | Skip: ${SKIP}"
echo "  Duration: ${TOTAL_TIME}s"
echo "=============================================="

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
