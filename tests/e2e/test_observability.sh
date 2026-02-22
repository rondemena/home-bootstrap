#!/usr/bin/env bash
# End-to-end integration test for observability stack (US4 - T048)
# Usage: ./tests/e2e/test_observability.sh
#
# Validates:
#   1. Prometheus scrape targets are up for key SDLC services
#   2. Grafana dashboards are loaded and accessible
#   3. Loki is receiving logs (LogQL query returns results)
#
# Optional environment variables:
#   INGRESS_DOMAIN    - Base domain (default: apps.lab.demena.net)
#   GRAFANA_USER      - Grafana admin username (default: admin)
#   GRAFANA_PASS      - Grafana admin password (default: admin)
#   TIMEOUT           - Per-request timeout in seconds (default: 30)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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
INGRESS_DOMAIN="${INGRESS_DOMAIN:-apps.${DOMAIN:-lab.demena.net}}"
PROMETHEUS_URL="https://prometheus.${INGRESS_DOMAIN}"
GRAFANA_URL="https://grafana.${INGRESS_DOMAIN}"
LOKI_URL="https://loki.${INGRESS_DOMAIN}"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"
TIMEOUT="${TIMEOUT:-30}"

# ---------------------------------------------------------------------------
# Section 1: Prometheus scrape target validation
# ---------------------------------------------------------------------------

# check_prometheus_target: verify a Prometheus scrape target is "up"
# Arguments:
#   $1 - descriptive name for the target
#   $2 - job name or label selector to match in the targets API response
check_prometheus_target() {
    local name="$1"
    local job_pattern="$2"

    log_info "Checking Prometheus target: ${name} (job=~${job_pattern})"

    local response
    response=$(curl -sk \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        "${PROMETHEUS_URL}/api/v1/targets" 2>/dev/null) || true

    if [[ -z "${response}" ]]; then
        log_fail "${name} - could not query Prometheus targets API"
        return 0
    fi

    # Check for the target status using the job pattern
    # activeTargets[].labels.job should match, and health should be "up"
    local target_health
    target_health=$(echo "${response}" | jq -r \
        --arg pat "${job_pattern}" \
        '[.data.activeTargets[] | select(.labels.job | test($pat))] |
         if length == 0 then "not_found"
         elif all(.health == "up") then "up"
         else "down"
         end' 2>/dev/null) || true

    case "${target_health}" in
        "up")
            log_pass "${name} - scrape target UP"
            ;;
        "down")
            log_fail "${name} - scrape target DOWN"
            ;;
        "not_found")
            log_fail "${name} - scrape target not found (job=~${job_pattern})"
            ;;
        *)
            log_fail "${name} - unexpected target status: ${target_health}"
            ;;
    esac
}

test_prometheus_targets() {
    log_section "Prometheus Scrape Targets"

    # Verify Prometheus itself is reachable
    local prom_code
    prom_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout "${TIMEOUT}" \
        "${PROMETHEUS_URL}/-/healthy" 2>/dev/null) || true

    if [[ "${prom_code}" != "200" ]]; then
        log_fail "Prometheus not reachable (HTTP ${prom_code})"
        log_skip "Skipping individual target checks (Prometheus unreachable)"
        return 0
    fi
    log_pass "Prometheus API reachable"

    # Check key SDLC service scrape targets
    # Job names depend on ServiceMonitor/PodMonitor naming, which varies by chart.
    # Use regex patterns broad enough to match common naming conventions.
    check_prometheus_target "Kubernetes API Server" "apiserver"
    check_prometheus_target "Kubernetes Nodes (kubelet)" "kubelet"
    check_prometheus_target "Node Exporter" "node-exporter|node_exporter"
    check_prometheus_target "CoreDNS" "coredns|kube-dns"
    check_prometheus_target "ArgoCD" "argocd"
    check_prometheus_target "GitLab" "gitlab"
    check_prometheus_target "Jenkins" "jenkins"
    check_prometheus_target "Harbor" "harbor"
    check_prometheus_target "Longhorn" "longhorn"
    check_prometheus_target "Grafana" "grafana"
    check_prometheus_target "Loki" "loki"
}

# ---------------------------------------------------------------------------
# Section 2: Grafana dashboard validation
# ---------------------------------------------------------------------------

test_grafana_dashboards() {
    log_section "Grafana Dashboards"

    # Verify Grafana API is reachable
    local grafana_health
    grafana_health=$(curl -sk \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
        "${GRAFANA_URL}/api/health" 2>/dev/null) || true

    local grafana_db_status
    grafana_db_status=$(echo "${grafana_health}" | jq -r '.database // "unknown"' 2>/dev/null) || true

    if [[ "${grafana_db_status}" == "ok" ]]; then
        log_pass "Grafana API healthy (database: ok)"
    elif [[ -n "${grafana_health}" ]]; then
        log_fail "Grafana API returned unexpected health status: ${grafana_db_status}"
    else
        log_fail "Grafana API not reachable"
        log_skip "Skipping dashboard checks (Grafana unreachable)"
        return 0
    fi

    # Query all dashboards
    local dashboards_response
    dashboards_response=$(curl -sk \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
        "${GRAFANA_URL}/api/search?query=&type=dash-db" 2>/dev/null) || true

    local dashboard_count
    dashboard_count=$(echo "${dashboards_response}" | jq 'length // 0' 2>/dev/null) || dashboard_count=0

    if [[ "${dashboard_count}" -gt 0 ]]; then
        log_pass "Grafana has ${dashboard_count} dashboard(s) loaded"
    else
        log_fail "No dashboards found in Grafana"
        return 0
    fi

    # Check for specific expected dashboards by searching for key terms
    local expected_dashboards=(
        "cluster"
        "node"
        "kubernetes"
    )

    for keyword in "${expected_dashboards[@]}"; do
        local search_response
        search_response=$(curl -sk \
            --connect-timeout "${TIMEOUT}" \
            --max-time "${TIMEOUT}" \
            -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
            "${GRAFANA_URL}/api/search?query=${keyword}&type=dash-db" 2>/dev/null) || true

        local match_count
        match_count=$(echo "${search_response}" | jq 'length // 0' 2>/dev/null) || match_count=0

        if [[ "${match_count}" -gt 0 ]]; then
            local first_title
            first_title=$(echo "${search_response}" | jq -r '.[0].title // "untitled"' 2>/dev/null)
            log_pass "Dashboard found for '${keyword}': ${first_title} (+${match_count} total)"
        else
            log_fail "No dashboard found matching '${keyword}'"
        fi
    done

    # Verify Grafana datasources include Prometheus and Loki
    local datasources_response
    datasources_response=$(curl -sk \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
        "${GRAFANA_URL}/api/datasources" 2>/dev/null) || true

    local prom_ds
    prom_ds=$(echo "${datasources_response}" | jq -r \
        '[.[] | select(.type == "prometheus")] | length' 2>/dev/null) || prom_ds=0

    if [[ "${prom_ds}" -gt 0 ]]; then
        log_pass "Grafana has Prometheus datasource configured"
    else
        log_fail "Grafana missing Prometheus datasource"
    fi

    local loki_ds
    loki_ds=$(echo "${datasources_response}" | jq -r \
        '[.[] | select(.type == "loki")] | length' 2>/dev/null) || loki_ds=0

    if [[ "${loki_ds}" -gt 0 ]]; then
        log_pass "Grafana has Loki datasource configured"
    else
        log_fail "Grafana missing Loki datasource"
    fi
}

# ---------------------------------------------------------------------------
# Section 3: Loki log ingestion validation
# ---------------------------------------------------------------------------

test_loki_logs() {
    log_section "Loki Log Ingestion"

    # Verify Loki is ready
    local loki_code
    loki_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        "${LOKI_URL}/ready" 2>/dev/null) || true

    if [[ "${loki_code}" == "200" ]]; then
        log_pass "Loki is ready"
    else
        log_fail "Loki not ready (HTTP ${loki_code})"
        log_skip "Skipping log queries (Loki not ready)"
        return 0
    fi

    # Query Loki for recent logs using LogQL
    # Use a broad query to verify logs are being collected from any namespace
    # Loki expects nanosecond-precision Unix timestamps
    local end_epoch start_epoch end_time start_time
    end_epoch=$(date -u +%s)
    end_time="${end_epoch}000000000"
    # GNU date uses -d, BSD/macOS date uses -v
    start_epoch=$(date -u -d '15 minutes ago' +%s 2>/dev/null || date -u -v-15M +%s 2>/dev/null || echo "$((end_epoch - 900))")
    start_time="${start_epoch}000000000"

    # Test 1: Query for logs from kube-system namespace (should always have logs)
    local query_response
    query_response=$(curl -sk \
        --connect-timeout "${TIMEOUT}" \
        --max-time "${TIMEOUT}" \
        -G "${LOKI_URL}/loki/api/v1/query_range" \
        --data-urlencode "query={namespace=\"kube-system\"}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "limit=5" 2>/dev/null) || true

    local query_status
    query_status=$(echo "${query_response}" | jq -r '.status // "error"' 2>/dev/null) || query_status="error"

    if [[ "${query_status}" == "success" ]]; then
        local result_count
        result_count=$(echo "${query_response}" | jq \
            '[.data.result[].values | length] | add // 0' 2>/dev/null) || result_count=0

        if [[ "${result_count}" -gt 0 ]]; then
            log_pass "Loki has logs from kube-system namespace (${result_count} entries)"
        else
            log_fail "Loki query succeeded but returned no logs from kube-system"
        fi
    else
        log_fail "Loki query failed (status: ${query_status})"
    fi

    # Test 2: Verify logs exist from the SDLC application namespaces
    local app_namespaces=("gitlab" "jenkins" "harbor" "argocd" "monitoring" "logging")

    for ns in "${app_namespaces[@]}"; do
        local ns_response
        ns_response=$(curl -sk \
            --connect-timeout "${TIMEOUT}" \
            --max-time "${TIMEOUT}" \
            -G "${LOKI_URL}/loki/api/v1/query_range" \
            --data-urlencode "query={namespace=\"${ns}\"}" \
            --data-urlencode "start=${start_time}" \
            --data-urlencode "end=${end_time}" \
            --data-urlencode "limit=1" 2>/dev/null) || true

        local ns_status
        ns_status=$(echo "${ns_response}" | jq -r '.status // "error"' 2>/dev/null) || ns_status="error"

        if [[ "${ns_status}" == "success" ]]; then
            local ns_count
            ns_count=$(echo "${ns_response}" | jq \
                '[.data.result[].values | length] | add // 0' 2>/dev/null) || ns_count=0

            if [[ "${ns_count}" -gt 0 ]]; then
                log_pass "Loki receiving logs from namespace '${ns}'"
            else
                log_fail "Loki has no logs from namespace '${ns}'"
            fi
        else
            log_fail "Loki query failed for namespace '${ns}' (status: ${ns_status})"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "============================================"
echo "  Observability Integration Test (US4 - T048)"
echo "============================================"
echo ""
echo "  Prometheus: ${PROMETHEUS_URL}"
echo "  Grafana:    ${GRAFANA_URL}"
echo "  Loki:       ${LOKI_URL}"

test_prometheus_targets
test_grafana_dashboards
test_loki_logs

echo ""
echo "============================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} (${TOTAL} total)"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
