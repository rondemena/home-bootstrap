#!/usr/bin/env bash
# Integration test for VM provisioning (US2)
# Usage: ./tests/e2e/test_vm_provision.sh
# Validates VMs are running, SSH accessible, and cloud-init complete

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source .env for environment-specific overrides (DOMAIN, PVE_HOST, DNS_SERVER, etc.)
# When run via test-e2e.sh the .env is already sourced; this allows standalone execution.
if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

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

# Expected VMs from data model.
# These IPs must match the OpenTofu VM configuration (code/tofu/envs/prod/*.tfvars).
# Override individual IPs via environment: VM_IP_K3S_SERVER_01, VM_IP_K3S_AGENT_01, etc.
declare -A VMS=(
    ["k3s-server-01"]="${VM_IP_K3S_SERVER_01:-192.168.2.100}"
    ["k3s-server-02"]="${VM_IP_K3S_SERVER_02:-192.168.2.101}"
    ["k3s-server-03"]="${VM_IP_K3S_SERVER_03:-192.168.2.102}"
    ["k3s-agent-01"]="${VM_IP_K3S_AGENT_01:-192.168.2.200}"
    ["k3s-agent-02"]="${VM_IP_K3S_AGENT_02:-192.168.2.201}"
)

# PVE_HOST: Proxmox host IP. Derived from PVE_API_URL if set, otherwise defaults.
PVE_HOST="${PVE_HOST:-192.168.2.11}"
SSH_USER="${SSH_USER:-admin}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_ed25519}"
# DNS_SERVER: gateway / DNS used for network reachability checks (from .env)
DNS_SERVER="${DNS_SERVER:-192.168.2.1}"

echo "============================================"
echo "  VM Provisioning Integration Tests (US2)"
echo "============================================"
echo ""

# Test 1: Proxmox API reachability
test_proxmox_api() {
    log_info "Testing Proxmox API at ${PVE_HOST}:8006..."
    if curl -sk --connect-timeout 10 "https://${PVE_HOST}:8006/api2/json/version" > /dev/null 2>&1; then
        log_pass "Proxmox API reachable"
    else
        log_fail "Proxmox API not reachable at ${PVE_HOST}:8006"
        return 1
    fi
}

# Test 2: VM exists and is running
test_vm_running() {
    local vm_name="$1"
    local vm_ip="$2"
    log_info "Checking VM ${vm_name} (${vm_ip})..."

    if ping -c 1 -W 3 "${vm_ip}" > /dev/null 2>&1; then
        log_pass "VM ${vm_name} is reachable at ${vm_ip}"
    else
        log_fail "VM ${vm_name} not reachable at ${vm_ip}"
    fi
}

# Test 3: SSH accessible
test_ssh_access() {
    local vm_name="$1"
    local vm_ip="$2"
    log_info "Testing SSH to ${vm_name}..."

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "${SSH_KEY}" "${SSH_USER}@${vm_ip}" "hostname" > /dev/null 2>&1; then
        log_pass "SSH accessible on ${vm_name}"
    else
        log_fail "SSH not accessible on ${vm_name}"
    fi
}

# Test 4: Cloud-init complete
test_cloud_init() {
    local vm_name="$1"
    local vm_ip="$2"
    log_info "Checking cloud-init status on ${vm_name}..."

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "${SSH_KEY}" "${SSH_USER}@${vm_ip}" \
        "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; then
        log_pass "Cloud-init complete on ${vm_name}"
    else
        log_fail "Cloud-init not complete on ${vm_name}"
    fi
}

# Test 5: Correct IP and gateway
test_network() {
    local vm_name="$1"
    local vm_ip="$2"
    log_info "Testing network on ${vm_name}..."

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "${SSH_KEY}" "${SSH_USER}@${vm_ip}" \
        "ping -c 1 -W 2 ${DNS_SERVER}" > /dev/null 2>&1; then
        log_pass "Gateway (${DNS_SERVER}) reachable from ${vm_name}"
    else
        log_fail "Gateway (${DNS_SERVER}) not reachable from ${vm_name}"
    fi
}

# Run tests
test_proxmox_api

for vm_name in "${!VMS[@]}"; do
    vm_ip="${VMS[$vm_name]}"
    echo ""
    log_info "--- Testing VM: ${vm_name} (${vm_ip}) ---"
    test_vm_running "${vm_name}" "${vm_ip}"
    test_ssh_access "${vm_name}" "${vm_ip}"
    test_cloud_init "${vm_name}" "${vm_ip}"
    test_network "${vm_name}" "${vm_ip}"
done

echo ""
echo "============================================"
echo "  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
