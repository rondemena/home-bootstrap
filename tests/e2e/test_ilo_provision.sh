#!/usr/bin/env bash
# Integration test for iLO provisioning (US1)
# Usage: ./tests/e2e/test_ilo_provision.sh [ILO_HOST]
# Validates BIOS settings match desired state and Proxmox API is reachable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
log_info() { echo -e "[INFO] $1"; }

# Parse inventory for iLO targets
ILO_HOST="${1:-}"

if [[ -z "${ILO_HOST}" ]]; then
    log_info "No ILO_HOST specified, testing all targets from inventory"
    log_skip "Inventory-based testing not yet implemented"
fi

# Test 1: iLO Redfish API reachability
test_ilo_reachable() {
    local host="$1"
    log_info "Testing iLO reachability at ${host}..."

    if curl -sk --connect-timeout 10 "https://${host}/redfish/v1/" > /dev/null 2>&1; then
        log_pass "iLO Redfish API reachable at ${host}"
    else
        log_fail "iLO Redfish API not reachable at ${host}"
        return 1
    fi
}

# Test 2: BIOS virtualization settings
test_bios_virtualization() {
    local host="$1"
    log_info "Checking BIOS virtualization settings on ${host}..."

    local bios_response
    bios_response=$(curl -sk -u "${ILO_USER:-ansible-svc}:${ILO_PASS:-}" \
        "https://${host}/redfish/v1/Systems/1/Bios/" 2>/dev/null)

    if [[ -z "${bios_response}" ]]; then
        log_fail "Could not query BIOS settings on ${host}"
        return 1
    fi

    # Check VT-x (Intel Virtualization Technology)
    local vt_enabled
    vt_enabled=$(echo "${bios_response}" | jq -r '.Attributes.ProcVirtualization // empty' 2>/dev/null)
    if [[ "${vt_enabled}" == "Enabled" ]]; then
        log_pass "VT-x enabled on ${host}"
    else
        log_fail "VT-x not enabled on ${host} (got: ${vt_enabled:-unknown})"
    fi

    # Check VT-d (Intel VT for Directed I/O)
    local vtd_enabled
    vtd_enabled=$(echo "${bios_response}" | jq -r '.Attributes.IntelligentProvisioningMode // empty' 2>/dev/null)
    log_info "VT-d check: additional BIOS attribute validation needed"
}

# Test 3: Boot mode
test_boot_mode() {
    local host="$1"
    log_info "Checking boot mode on ${host}..."

    local boot_response
    boot_response=$(curl -sk -u "${ILO_USER:-ansible-svc}:${ILO_PASS:-}" \
        "https://${host}/redfish/v1/Systems/1/" 2>/dev/null)

    local boot_mode
    boot_mode=$(echo "${boot_response}" | jq -r '.Boot.BootSourceOverrideMode // empty' 2>/dev/null)

    if [[ "${boot_mode}" == "UEFI" ]]; then
        log_pass "Boot mode is UEFI on ${host}"
    else
        log_fail "Boot mode is not UEFI on ${host} (got: ${boot_mode:-unknown})"
    fi
}

# Test 4: Proxmox API reachability (post-install verification)
test_proxmox_api() {
    local pve_host="$1"
    log_info "Testing Proxmox API at ${pve_host}:8006..."

    if curl -sk --connect-timeout 10 "https://${pve_host}:8006/api2/json/version" > /dev/null 2>&1; then
        log_pass "Proxmox API reachable at ${pve_host}:8006"
    else
        log_fail "Proxmox API not reachable at ${pve_host}:8006"
    fi
}

# Test 5: Virtual media not mounted (post-install cleanup)
test_virtual_media_ejected() {
    local host="$1"
    log_info "Checking virtual media state on ${host}..."

    local media_response
    media_response=$(curl -sk -u "${ILO_USER:-ansible-svc}:${ILO_PASS:-}" \
        "https://${host}/redfish/v1/Managers/1/VirtualMedia/2/" 2>/dev/null)

    local inserted
    inserted=$(echo "${media_response}" | jq -r '.Inserted // false' 2>/dev/null)

    if [[ "${inserted}" == "false" ]]; then
        log_pass "Virtual media ejected on ${host}"
    else
        log_fail "Virtual media still mounted on ${host}"
    fi
}

# Main execution
echo "============================================"
echo "  iLO Provisioning Integration Tests (US1)"
echo "============================================"
echo ""

if [[ -n "${ILO_HOST}" ]]; then
    test_ilo_reachable "${ILO_HOST}"
    test_bios_virtualization "${ILO_HOST}"
    test_boot_mode "${ILO_HOST}"
    test_virtual_media_ejected "${ILO_HOST}"

    # Derive Proxmox management IP from iLO IP
    # Convention: 192.168.5.x (iLO) maps to 192.168.2.x (management)
    PVE_HOST="${ILO_HOST/192.168.5./192.168.2.}"
    test_proxmox_api "${PVE_HOST}"
fi

echo ""
echo "============================================"
echo "  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
