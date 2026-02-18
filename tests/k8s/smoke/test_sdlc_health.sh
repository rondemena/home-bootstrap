#!/usr/bin/env bash
# Health check smoke test for all SDLC services (US4 - T046)
# Usage: ./tests/k8s/smoke/test_sdlc_health.sh
# Validates HTTP health endpoints for every SDLC service in the stack
#
# Environment variables:
#   INGRESS_DOMAIN  - Base domain for services (default: apps.home.lab)
#   TIMEOUT         - Per-service HTTP timeout in seconds (default: 30)
#   SKIP_SECONDARY  - Set to "true" to skip secondary stack (Gitea, Woodpecker)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
export REPO_ROOT  # available to child processes

# Source .env for environment-specific overrides (DOMAIN, INGRESS_DOMAIN, etc.)
# When run via test-e2e.sh the .env is already sourced; this allows standalone execution.
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
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
log_info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
log_section() { echo -e "\n${BOLD}--- $1 ---${NC}"; }

# Configuration
# INGRESS_DOMAIN: derived from DOMAIN if not set directly (both defined in .env)
INGRESS_DOMAIN="${INGRESS_DOMAIN:-apps.${DOMAIN:-home.lab}}"
TIMEOUT="${TIMEOUT:-30}"
SKIP_SECONDARY="${SKIP_SECONDARY:-false}"

# check_health: probe an HTTP(S) endpoint and validate the response code
# Arguments:
#   $1 - service display name
#   $2 - full URL to probe
#   $3 - comma-separated list of acceptable HTTP status codes (e.g., "200" or "200,302")
#   $4 - (optional) "secondary" to mark as secondary stack
check_health() {
    local name="$1"
    local url="$2"
    local expected_codes="$3"
    local stack="${4:-primary}"

    if [[ "${stack}" == "secondary" && "${SKIP_SECONDARY}" == "true" ]]; then
        log_skip "${name} (secondary stack skipped)"
        return 0
    fi

    log_info "Probing ${name} at ${url} ..."

    local http_code
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        "${url}" 2>/dev/null) || true

    if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
        log_fail "${name} - connection failed (timeout or unreachable)"
        return 0
    fi

    # Check if the returned code is in the list of acceptable codes
    local code_match=false
    IFS=',' read -ra codes <<< "${expected_codes}"
    for code in "${codes[@]}"; do
        if [[ "${http_code}" == "${code}" ]]; then
            code_match=true
            break
        fi
    done

    if [[ "${code_match}" == "true" ]]; then
        log_pass "${name} - HTTP ${http_code}"
    else
        log_fail "${name} - expected HTTP ${expected_codes}, got HTTP ${http_code}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "============================================"
echo "  SDLC Service Health Checks (US4 - T046)"
echo "============================================"
echo ""
echo "  Domain:    *.${INGRESS_DOMAIN}"
echo "  Timeout:   ${TIMEOUT}s per service"
echo "  Secondary: $(if [[ "${SKIP_SECONDARY}" == "true" ]]; then echo "skipped"; else echo "included"; fi)"

# ---- Primary SDLC Stack ----

log_section "Primary SDLC Stack"

check_health \
    "GitLab CE" \
    "https://gitlab.${INGRESS_DOMAIN}/-/health" \
    "200"

check_health \
    "Jenkins" \
    "https://jenkins.${INGRESS_DOMAIN}/login" \
    "200"

check_health \
    "Harbor" \
    "https://harbor.${INGRESS_DOMAIN}/api/v2.0/health" \
    "200"

check_health \
    "ArgoCD" \
    "https://argocd.${INGRESS_DOMAIN}" \
    "200,302"

# ---- Observability Stack ----

log_section "Observability Stack"

check_health \
    "Prometheus" \
    "https://prometheus.${INGRESS_DOMAIN}/-/healthy" \
    "200"

check_health \
    "Grafana" \
    "https://grafana.${INGRESS_DOMAIN}/api/health" \
    "200"

check_health \
    "Loki" \
    "https://loki.${INGRESS_DOMAIN}/ready" \
    "200"

# ---- Secondary SDLC Stack ----

log_section "Secondary SDLC Stack"

check_health \
    "Gitea" \
    "https://gitea.${INGRESS_DOMAIN}/api/healthz" \
    "200" \
    "secondary"

check_health \
    "Woodpecker CI" \
    "https://ci.${INGRESS_DOMAIN}/healthz" \
    "200" \
    "secondary"

# ---- Summary ----

echo ""
echo "============================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} (${TOTAL} total)"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
