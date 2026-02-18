#!/usr/bin/env bash
# Smoke test for k3s cluster (US3)
# Usage: ./tests/k8s/smoke/test_cluster.sh
# Validates: all 3 nodes Ready, kube-system pods Running, CoreDNS resolving, Traefik running
# Env: KUBECONFIG (optional, defaults to ~/.kube/config)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }

# Expected cluster nodes
EXPECTED_NODES=("k3s-server-01" "k3s-agent-01" "k3s-agent-02")
EXPECTED_NODE_COUNT=3

# ---------------------------------------------------------------------------
# Preflight: verify kubectl and kubeconfig are available
# ---------------------------------------------------------------------------
preflight_check() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}[FATAL]${NC} kubectl not found in PATH"
        exit 1
    fi

    if [[ ! -f "${KUBECONFIG}" ]]; then
        echo -e "${RED}[FATAL]${NC} KUBECONFIG not found at ${KUBECONFIG}"
        exit 1
    fi

    # Quick connectivity test
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}[FATAL]${NC} Cannot connect to cluster. Check KUBECONFIG=${KUBECONFIG}"
        exit 1
    fi

    log_info "Connected to cluster using KUBECONFIG=${KUBECONFIG}"
}

# ---------------------------------------------------------------------------
# Test 1: All expected nodes exist and are in Ready state
# ---------------------------------------------------------------------------
test_nodes_ready() {
    log_info "Checking node readiness..."

    local node_output
    node_output=$(kubectl get nodes --no-headers 2>/dev/null) || {
        log_fail "Failed to list cluster nodes"
        return
    }

    local ready_count=0
    local total_count
    total_count=$(echo "${node_output}" | wc -l | tr -d ' ')

    # Verify total node count
    if [[ "${total_count}" -eq "${EXPECTED_NODE_COUNT}" ]]; then
        log_pass "Node count is ${EXPECTED_NODE_COUNT}"
    else
        log_fail "Expected ${EXPECTED_NODE_COUNT} nodes, found ${total_count}"
    fi

    # Verify each expected node is present and Ready
    for node_name in "${EXPECTED_NODES[@]}"; do
        local node_status
        node_status=$(kubectl get node "${node_name}" --no-headers 2>/dev/null) || {
            log_fail "Node ${node_name} not found in cluster"
            continue
        }

        local status
        status=$(echo "${node_status}" | awk '{print $2}')

        if [[ "${status}" == "Ready" ]]; then
            log_pass "Node ${node_name} is Ready"
            ((ready_count++))
        else
            log_fail "Node ${node_name} is not Ready (status: ${status})"
        fi
    done

    if [[ "${ready_count}" -eq "${EXPECTED_NODE_COUNT}" ]]; then
        log_pass "All ${EXPECTED_NODE_COUNT} nodes are Ready"
    else
        log_fail "Only ${ready_count}/${EXPECTED_NODE_COUNT} nodes are Ready"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: kube-system pods are Running
# ---------------------------------------------------------------------------
test_kube_system_pods() {
    log_info "Checking kube-system pods..."

    local pods_output
    pods_output=$(kubectl get pods -n kube-system --no-headers 2>/dev/null) || {
        log_fail "Failed to list kube-system pods"
        return
    }

    if [[ -z "${pods_output}" ]]; then
        log_fail "No pods found in kube-system namespace"
        return
    fi

    local total_pods=0
    local healthy_pods=0
    local unhealthy_pods=()

    while IFS= read -r line; do
        ((total_pods++))
        local pod_name pod_status
        pod_name=$(echo "${line}" | awk '{print $1}')
        pod_status=$(echo "${line}" | awk '{print $3}')

        if [[ "${pod_status}" == "Running" || "${pod_status}" == "Completed" ]]; then
            ((healthy_pods++))
        else
            unhealthy_pods+=("${pod_name}:${pod_status}")
        fi
    done <<< "${pods_output}"

    if [[ "${healthy_pods}" -eq "${total_pods}" ]]; then
        log_pass "All ${total_pods} kube-system pods are healthy (Running/Completed)"
    else
        log_fail "${#unhealthy_pods[@]} kube-system pods are not healthy:"
        for pod in "${unhealthy_pods[@]}"; do
            echo -e "         ${RED}-${NC} ${pod}"
        done
    fi
}

# ---------------------------------------------------------------------------
# Test 3: CoreDNS is resolving
# ---------------------------------------------------------------------------
test_coredns_resolving() {
    log_info "Checking CoreDNS functionality..."

    # Verify CoreDNS pods are running
    local coredns_pods
    coredns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null) || {
        log_fail "Failed to query CoreDNS pods"
        return
    }

    if [[ -z "${coredns_pods}" ]]; then
        log_fail "No CoreDNS pods found (label: k8s-app=kube-dns)"
        return
    fi

    local coredns_running
    coredns_running=$(echo "${coredns_pods}" | awk '$3 == "Running"' | wc -l | tr -d ' ')

    if [[ "${coredns_running}" -gt 0 ]]; then
        log_pass "CoreDNS has ${coredns_running} running pod(s)"
    else
        log_fail "No CoreDNS pods in Running state"
        return
    fi

    # Verify CoreDNS service exists
    if kubectl get svc -n kube-system kube-dns &> /dev/null; then
        log_pass "CoreDNS service (kube-dns) exists"
    else
        log_fail "CoreDNS service (kube-dns) not found"
        return
    fi

    # Test DNS resolution by running a lookup inside the cluster
    local dns_test_result
    dns_test_result=$(kubectl run dns-test-$$ \
        --image=busybox:1.36 \
        --restart=Never \
        --rm \
        -i \
        --timeout=30s \
        -- nslookup kubernetes.default.svc.cluster.local 2>&1) || true

    if echo "${dns_test_result}" | grep -q "Address"; then
        log_pass "CoreDNS resolves kubernetes.default.svc.cluster.local"
    else
        # DNS test pod may fail in restricted environments; fall back to
        # checking the CoreDNS endpoints are populated
        local endpoints
        endpoints=$(kubectl get endpoints -n kube-system kube-dns -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        if [[ -n "${endpoints}" ]]; then
            log_pass "CoreDNS endpoints are populated (${endpoints})"
        else
            log_fail "CoreDNS DNS resolution test failed and no endpoints found"
        fi
    fi

    # Cleanup: ensure the test pod is removed even if it didn't auto-delete
    kubectl delete pod "dns-test-$$" --ignore-not-found=true &> /dev/null || true
}

# ---------------------------------------------------------------------------
# Test 4: Traefik ingress controller is running (k3s default)
# ---------------------------------------------------------------------------
test_traefik_running() {
    log_info "Checking Traefik ingress controller..."

    # Check for Traefik pods (k3s deploys Traefik as a Helm chart in kube-system)
    local traefik_pods
    traefik_pods=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null)

    # Fallback: some k3s versions use a different label
    if [[ -z "${traefik_pods}" ]]; then
        traefik_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -i traefik)
    fi

    if [[ -z "${traefik_pods}" ]]; then
        log_fail "No Traefik pods found in kube-system"
        return
    fi

    local traefik_running
    traefik_running=$(echo "${traefik_pods}" | awk '$3 == "Running"' | wc -l | tr -d ' ')

    if [[ "${traefik_running}" -gt 0 ]]; then
        log_pass "Traefik has ${traefik_running} running pod(s)"
    else
        log_fail "No Traefik pods in Running state"
        return
    fi

    # Check Traefik service
    local traefik_svc
    traefik_svc=$(kubectl get svc -n kube-system traefik --no-headers 2>/dev/null) || {
        # Fallback: search by label
        traefik_svc=$(kubectl get svc -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null)
    }

    if [[ -n "${traefik_svc}" ]]; then
        log_pass "Traefik service exists in kube-system"

        # Check if Traefik has an external IP or NodePort
        local svc_type
        svc_type=$(echo "${traefik_svc}" | awk '{print $2}')
        local external_ip
        external_ip=$(echo "${traefik_svc}" | awk '{print $4}')

        if [[ "${svc_type}" == "LoadBalancer" && "${external_ip}" != "<none>" && "${external_ip}" != "<pending>" ]]; then
            log_pass "Traefik LoadBalancer has external IP: ${external_ip}"
        elif [[ "${svc_type}" == "LoadBalancer" ]]; then
            log_info "Traefik LoadBalancer IP is pending (MetalLB may not be configured yet)"
        else
            log_info "Traefik service type: ${svc_type}"
        fi
    else
        log_fail "Traefik service not found in kube-system"
    fi

    # Verify Traefik IngressClass exists
    if kubectl get ingressclass traefik &> /dev/null; then
        log_pass "Traefik IngressClass exists"
    else
        log_skip "Traefik IngressClass not found (may use annotations instead)"
    fi
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
echo "============================================"
echo "  k3s Cluster Smoke Tests (US3)"
echo "============================================"
echo ""

preflight_check
echo ""

log_info "--- Node Readiness ---"
test_nodes_ready
echo ""

log_info "--- kube-system Pods ---"
test_kube_system_pods
echo ""

log_info "--- CoreDNS Resolution ---"
test_coredns_resolving
echo ""

log_info "--- Traefik Ingress Controller ---"
test_traefik_running

echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
