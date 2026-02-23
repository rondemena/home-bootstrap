#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Orchestration Script for home-bootstrap
# Runs all layers sequentially with progress reporting and resume support

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_FILE="${REPO_ROOT}/.bootstrap-state"

# Source .env if present
if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# Check if a layer is already completed (resume support)
layer_done() {
    local layer="$1"
    if [[ -f "${STATE_FILE}" ]] && grep -q "^${layer}$" "${STATE_FILE}"; then
        return 0
    fi
    return 1
}

mark_done() {
    local layer="$1"
    echo "${layer}" >> "${STATE_FILE}"
}

run_layer() {
    local name="$1"
    local command="$2"

    if layer_done "${name}"; then
        log_warn "Skipping ${name} (already completed). Delete ${STATE_FILE} to re-run."
        return 0
    fi

    log_info "Starting: ${name}"
    local start
    start=$(date +%s)

    if eval "${command}"; then
        local end
        end=$(date +%s)
        log_info "Completed: ${name} ($((end - start))s)"
        mark_done "${name}"
    else
        log_error "Failed: ${name}"
        log_error "Fix the issue and re-run this script to resume from this layer."
        exit 1
    fi
}

echo "=============================================="
echo "  home-bootstrap Full Bootstrap"
echo "  $(date -Iseconds)"
echo "=============================================="
echo ""

if [[ -f "${STATE_FILE}" ]]; then
    log_warn "Resuming from previous run. Completed layers:"
    sed 's/^/  - /' "${STATE_FILE}"
    echo ""
fi

# Layer 1: Proxmox Configuration (skip iLO for DL380 - already installed)
run_layer "configure-proxmox" "make -C '${REPO_ROOT}' configure-proxmox"

# Layer 2: VM Provisioning
run_layer "provision-vms" "make -C '${REPO_ROOT}' provision-vms"

# Layer 3: k3s Cluster
run_layer "bootstrap-k3s" "make -C '${REPO_ROOT}' bootstrap-k3s"

# Layer 3b: Infrastructure Services
run_layer "deploy-infra" "make -C '${REPO_ROOT}' deploy-infra"

# Layer 4: ArgoCD + SDLC Applications
run_layer "deploy-apps" "make -C '${REPO_ROOT}' deploy-apps"

echo ""
log_info "=============================================="
log_info "  Bootstrap complete!"
log_info "  Run 'make test-e2e' to validate."
log_info "=============================================="
