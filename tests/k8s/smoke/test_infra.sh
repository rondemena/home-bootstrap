#!/usr/bin/env bash
# Infrastructure services integration test (US3)
# Usage: ./tests/k8s/smoke/test_infra.sh
# Validates: MetalLB IP assignment, Longhorn PVC binding,
#            cert-manager certificate issuance, Sealed Secrets controller
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

# Configuration
METALLB_POOL_START="192.168.2.240"
METALLB_POOL_END="192.168.2.250"
TEST_NAMESPACE="infra-test-$$"
CLEANUP_RESOURCES=()

# ---------------------------------------------------------------------------
# Cleanup handler - removes all test resources on exit
# ---------------------------------------------------------------------------
cleanup() {
    log_info "Cleaning up test resources..."

    for resource in "${CLEANUP_RESOURCES[@]}"; do
        log_info "Removing: ${resource}"
        kubectl delete ${resource} --ignore-not-found=true --timeout=30s &> /dev/null || true
    done

    # Delete the test namespace (catches anything we missed)
    kubectl delete namespace "${TEST_NAMESPACE}" --ignore-not-found=true --timeout=60s &> /dev/null || true

    log_info "Cleanup complete"
}

trap cleanup EXIT

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

    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}[FATAL]${NC} Cannot connect to cluster. Check KUBECONFIG=${KUBECONFIG}"
        exit 1
    fi

    # Create test namespace
    kubectl create namespace "${TEST_NAMESPACE}" &> /dev/null || true
    CLEANUP_RESOURCES+=("namespace/${TEST_NAMESPACE}")

    log_info "Connected to cluster, test namespace: ${TEST_NAMESPACE}"
}

# ---------------------------------------------------------------------------
# Helper: check if an IP is within the MetalLB pool range
# ---------------------------------------------------------------------------
ip_in_range() {
    local ip="$1"
    local start="$2"
    local end="$3"

    # Convert IP to integer for comparison
    local ip_int start_int end_int
    ip_int=$(printf '%d' "$(echo "${ip}" | awk -F. '{printf "0x%02x%02x%02x%02x", $1, $2, $3, $4}')")
    start_int=$(printf '%d' "$(echo "${start}" | awk -F. '{printf "0x%02x%02x%02x%02x", $1, $2, $3, $4}')")
    end_int=$(printf '%d' "$(echo "${end}" | awk -F. '{printf "0x%02x%02x%02x%02x", $1, $2, $3, $4}')")

    [[ "${ip_int}" -ge "${start_int}" && "${ip_int}" -le "${end_int}" ]]
}

# ---------------------------------------------------------------------------
# Test 1: MetalLB - Create LoadBalancer Service and verify IP assignment
# ---------------------------------------------------------------------------
test_metallb() {
    log_info "--- MetalLB Load Balancer ---"

    # Check MetalLB controller is running
    local metallb_pods
    metallb_pods=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null) || {
        log_fail "MetalLB namespace (metallb-system) not found"
        return
    }

    if [[ -z "${metallb_pods}" ]]; then
        log_fail "No MetalLB pods found in metallb-system"
        return
    fi

    local controller_running
    controller_running=$(echo "${metallb_pods}" | grep -c "controller.*Running" || true)
    local speaker_running
    speaker_running=$(echo "${metallb_pods}" | grep -c "speaker.*Running" || true)

    if [[ "${controller_running}" -gt 0 ]]; then
        log_pass "MetalLB controller is Running"
    else
        log_fail "MetalLB controller is not Running"
        return
    fi

    if [[ "${speaker_running}" -gt 0 ]]; then
        log_pass "MetalLB speaker(s) Running (${speaker_running} instance(s))"
    else
        log_fail "MetalLB speaker is not Running"
    fi

    # Create a test LoadBalancer Service
    log_info "Creating test LoadBalancer Service..."
    kubectl apply -n "${TEST_NAMESPACE}" -f - <<'YAML' &> /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metallb-test
  labels:
    app: metallb-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metallb-test
  template:
    metadata:
      labels:
        app: metallb-test
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
      terminationGracePeriodSeconds: 0
---
apiVersion: v1
kind: Service
metadata:
  name: metallb-test-svc
spec:
  type: LoadBalancer
  selector:
    app: metallb-test
  ports:
    - port: 80
      targetPort: 80
YAML
    CLEANUP_RESOURCES+=("-n ${TEST_NAMESPACE} deployment/metallb-test")
    CLEANUP_RESOURCES+=("-n ${TEST_NAMESPACE} service/metallb-test-svc")

    # Wait for an external IP to be assigned (up to 60 seconds)
    log_info "Waiting for LoadBalancer IP assignment (up to 60s)..."
    local assigned_ip=""
    local attempts=0
    local max_attempts=12

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        assigned_ip=$(kubectl get svc -n "${TEST_NAMESPACE}" metallb-test-svc \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

        if [[ -n "${assigned_ip}" && "${assigned_ip}" != "<none>" ]]; then
            break
        fi

        ((attempts++))
        sleep 5
    done

    if [[ -z "${assigned_ip}" || "${assigned_ip}" == "<none>" ]]; then
        log_fail "MetalLB did not assign an IP within 60s"
        return
    fi

    log_pass "MetalLB assigned IP: ${assigned_ip}"

    # Verify IP is within the expected pool range
    if ip_in_range "${assigned_ip}" "${METALLB_POOL_START}" "${METALLB_POOL_END}"; then
        log_pass "Assigned IP ${assigned_ip} is within pool range ${METALLB_POOL_START}-${METALLB_POOL_END}"
    else
        log_fail "Assigned IP ${assigned_ip} is outside expected pool range ${METALLB_POOL_START}-${METALLB_POOL_END}"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: Longhorn - Create PVC and verify it binds
# ---------------------------------------------------------------------------
test_longhorn() {
    log_info "--- Longhorn Storage ---"

    # Check Longhorn pods
    local longhorn_pods
    longhorn_pods=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null) || {
        log_fail "Longhorn namespace (longhorn-system) not found"
        return
    }

    if [[ -z "${longhorn_pods}" ]]; then
        log_fail "No Longhorn pods found in longhorn-system"
        return
    fi

    local running_count
    running_count=$(echo "${longhorn_pods}" | awk '$3 == "Running"' | wc -l | tr -d ' ')
    local total_count
    total_count=$(echo "${longhorn_pods}" | wc -l | tr -d ' ')

    if [[ "${running_count}" -gt 0 ]]; then
        log_pass "Longhorn has ${running_count}/${total_count} pods Running"
    else
        log_fail "No Longhorn pods in Running state"
        return
    fi

    # Verify Longhorn StorageClass exists
    if kubectl get storageclass longhorn &> /dev/null; then
        log_pass "Longhorn StorageClass exists"
    else
        log_fail "Longhorn StorageClass not found"
        return
    fi

    # Create test PVC
    log_info "Creating test PVC with Longhorn StorageClass..."
    kubectl apply -n "${TEST_NAMESPACE}" -f - <<'YAML' &> /dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
YAML
    CLEANUP_RESOURCES+=("-n ${TEST_NAMESPACE} pvc/longhorn-test-pvc")

    # Wait for PVC to bind (up to 90 seconds)
    log_info "Waiting for PVC to bind (up to 90s)..."
    local pvc_status=""
    local attempts=0
    local max_attempts=18

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        pvc_status=$(kubectl get pvc -n "${TEST_NAMESPACE}" longhorn-test-pvc \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)

        if [[ "${pvc_status}" == "Bound" ]]; then
            break
        fi

        ((attempts++))
        sleep 5
    done

    if [[ "${pvc_status}" == "Bound" ]]; then
        log_pass "Longhorn PVC bound successfully"

        # Get the PV name for additional verification
        local pv_name
        pv_name=$(kubectl get pvc -n "${TEST_NAMESPACE}" longhorn-test-pvc \
            -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
        if [[ -n "${pv_name}" ]]; then
            log_pass "PVC bound to PV: ${pv_name}"
            CLEANUP_RESOURCES+=("pv/${pv_name}")
        fi
    else
        log_fail "Longhorn PVC did not bind within 90s (status: ${pvc_status:-unknown})"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: cert-manager - Verify ClusterIssuer and certificate issuance
# ---------------------------------------------------------------------------
test_cert_manager() {
    log_info "--- cert-manager TLS ---"

    # Check cert-manager pods
    local cm_pods
    cm_pods=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null) || {
        log_fail "cert-manager namespace not found"
        return
    }

    if [[ -z "${cm_pods}" ]]; then
        log_fail "No cert-manager pods found"
        return
    fi

    local cm_running
    cm_running=$(echo "${cm_pods}" | awk '$3 == "Running"' | wc -l | tr -d ' ')

    if [[ "${cm_running}" -gt 0 ]]; then
        log_pass "cert-manager has ${cm_running} Running pod(s)"
    else
        log_fail "No cert-manager pods in Running state"
        return
    fi

    # Verify ClusterIssuer exists
    local issuers
    issuers=$(kubectl get clusterissuers --no-headers 2>/dev/null) || {
        log_fail "Failed to list ClusterIssuers (CRD may not be installed)"
        return
    }

    if [[ -n "${issuers}" ]]; then
        local issuer_names
        issuer_names=$(echo "${issuers}" | awk '{print $1}' | tr '\n' ', ' | sed 's/,$//')
        log_pass "ClusterIssuer(s) found: ${issuer_names}"
    else
        log_fail "No ClusterIssuers configured"
        return
    fi

    # Get the first available ClusterIssuer name for the test certificate
    local issuer_name
    issuer_name=$(echo "${issuers}" | awk 'NR==1{print $1}')

    # Create a test Certificate resource
    log_info "Creating test Certificate using ClusterIssuer '${issuer_name}'..."
    kubectl apply -n "${TEST_NAMESPACE}" -f - <<YAML &> /dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
spec:
  secretName: test-cert-tls
  duration: 1h
  renewBefore: 30m
  issuerRef:
    name: ${issuer_name}
    kind: ClusterIssuer
  dnsNames:
    - test.apps.home.lab
YAML
    CLEANUP_RESOURCES+=("-n ${TEST_NAMESPACE} certificate/test-cert")
    CLEANUP_RESOURCES+=("-n ${TEST_NAMESPACE} secret/test-cert-tls")

    # Wait for certificate to be issued (up to 90 seconds)
    log_info "Waiting for certificate issuance (up to 90s)..."
    local cert_ready=""
    local attempts=0
    local max_attempts=18

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        cert_ready=$(kubectl get certificate -n "${TEST_NAMESPACE}" test-cert \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

        if [[ "${cert_ready}" == "True" ]]; then
            break
        fi

        ((attempts++))
        sleep 5
    done

    if [[ "${cert_ready}" == "True" ]]; then
        log_pass "Test certificate issued successfully for test.apps.home.lab"
    else
        local cert_message
        cert_message=$(kubectl get certificate -n "${TEST_NAMESPACE}" test-cert \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
        log_fail "Certificate not issued within 90s (message: ${cert_message:-unknown})"
    fi

    # Verify the TLS secret was created
    if kubectl get secret -n "${TEST_NAMESPACE}" test-cert-tls &> /dev/null; then
        log_pass "TLS secret (test-cert-tls) created"
    else
        log_fail "TLS secret (test-cert-tls) not found"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: Sealed Secrets - Verify controller pod is running
# ---------------------------------------------------------------------------
test_sealed_secrets() {
    log_info "--- Sealed Secrets ---"

    # Sealed Secrets controller is typically deployed in kube-system
    local ss_pods
    ss_pods=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets --no-headers 2>/dev/null)

    # Fallback: search by name pattern if label does not match
    if [[ -z "${ss_pods}" ]]; then
        ss_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -i "sealed-secrets" || true)
    fi

    if [[ -z "${ss_pods}" ]]; then
        log_fail "Sealed Secrets controller pod not found in kube-system"
        return
    fi

    local ss_running
    ss_running=$(echo "${ss_pods}" | awk '$3 == "Running"' | wc -l | tr -d ' ')

    if [[ "${ss_running}" -gt 0 ]]; then
        log_pass "Sealed Secrets controller is Running"
    else
        local ss_status
        ss_status=$(echo "${ss_pods}" | awk '{print $1 ": " $3}')
        log_fail "Sealed Secrets controller is not Running (${ss_status})"
        return
    fi

    # Verify the SealedSecret CRD exists
    if kubectl get crd sealedsecrets.bitnami.com &> /dev/null; then
        log_pass "SealedSecret CRD is installed"
    else
        log_fail "SealedSecret CRD (sealedsecrets.bitnami.com) not found"
    fi

    # Verify the Sealed Secrets service exists (needed for kubeseal)
    local ss_svc
    ss_svc=$(kubectl get svc -n kube-system -l app.kubernetes.io/name=sealed-secrets --no-headers 2>/dev/null)

    if [[ -z "${ss_svc}" ]]; then
        ss_svc=$(kubectl get svc -n kube-system --no-headers 2>/dev/null | grep -i "sealed-secrets" || true)
    fi

    if [[ -n "${ss_svc}" ]]; then
        log_pass "Sealed Secrets service exists in kube-system"
    else
        log_skip "Sealed Secrets service not found (kubeseal may use port-forward)"
    fi
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
echo "============================================"
echo "  Infrastructure Services Integration Tests"
echo "  (US3 - MetalLB, Longhorn, cert-manager,"
echo "   Sealed Secrets)"
echo "============================================"
echo ""

preflight_check
echo ""

test_metallb
echo ""

test_longhorn
echo ""

test_cert_manager
echo ""

test_sealed_secrets

echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
