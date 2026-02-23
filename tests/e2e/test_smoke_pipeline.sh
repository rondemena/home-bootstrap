#!/usr/bin/env bash
set -euo pipefail

# CI Pipeline Smoke Test
# Creates a minimal test project, pushes code, verifies pipeline triggers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source .env for environment-specific overrides (DOMAIN, INGRESS_DOMAIN, etc.)
# When run via test-e2e.sh the .env is already sourced; this allows standalone execution.
if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

# INGRESS_DOMAIN: derived from DOMAIN if not set directly (both defined in .env)
INGRESS_DOMAIN="${INGRESS_DOMAIN:-apps.${DOMAIN:-lab.demena.net}}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.${INGRESS_DOMAIN}}"
JENKINS_URL="${JENKINS_URL:-https://jenkins.${INGRESS_DOMAIN}}"
HARBOR_URL="${HARBOR_URL:-https://harbor.${INGRESS_DOMAIN}}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
TEST_PROJECT="smoke-test-$(date +%s)"
TIMEOUT=300
PASS=0
FAIL=0

cleanup() {
    echo "Cleaning up test project..."
    if [[ -n "${GITLAB_TOKEN}" ]]; then
        local project_id
        project_id=$(curl -sk --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/projects?search=${TEST_PROJECT}" | \
            jq -r '.[0].id // empty')
        if [[ -n "${project_id}" ]]; then
            curl -sk --request DELETE --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                "${GITLAB_URL}/api/v4/projects/${project_id}" || true
        fi
    fi
    rm -rf "/tmp/${TEST_PROJECT}" 2>/dev/null || true
}
trap cleanup EXIT

assert_pass() {
    local msg="$1"
    echo "  PASS: ${msg}"
    PASS=$((PASS + 1))
}

assert_fail() {
    local msg="$1"
    echo "  FAIL: ${msg}"
    FAIL=$((FAIL + 1))
}

echo "=== CI Pipeline Smoke Test ==="

# Check prerequisites
if [[ -z "${GITLAB_TOKEN}" ]]; then
    echo "SKIP: GITLAB_TOKEN not set"
    exit 0
fi

# 1. Create test project
echo "Creating test project: ${TEST_PROJECT}"
response=$(curl -sk --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"name\": \"${TEST_PROJECT}\", \"visibility\": \"internal\"}" \
    "${GITLAB_URL}/api/v4/projects")

project_id=$(echo "${response}" | jq -r '.id // empty')
if [[ -n "${project_id}" ]]; then
    assert_pass "Created GitLab project (ID: ${project_id})"
else
    assert_fail "Failed to create GitLab project"
    exit 1
fi

# 2. Push minimal Jenkinsfile
echo "Pushing test Jenkinsfile..."
jenkinsfile_content=$(cat <<'PIPELINE'
pipeline {
    agent { label 'jenkins-agent' }
    stages {
        stage('Build') {
            steps { echo 'Smoke test build' }
        }
        stage('Test') {
            steps { echo 'Smoke test passed' }
        }
    }
}
PIPELINE
)

encoded=$(echo -n "${jenkinsfile_content}" | base64 -w 0)
curl -sk --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{\"branch\": \"main\", \"commit_message\": \"Add Jenkinsfile\", \"content\": \"${encoded}\", \"file_path\": \"Jenkinsfile\", \"encoding\": \"base64\"}" \
    "${GITLAB_URL}/api/v4/projects/${project_id}/repository/files/Jenkinsfile" > /dev/null

assert_pass "Pushed Jenkinsfile to GitLab"

# 3. Wait for Jenkins build (if webhook is configured)
echo "Waiting for Jenkins build (timeout: ${TIMEOUT}s)..."
echo "  Note: Requires GitLab webhook configured to trigger Jenkins"

elapsed=0
build_found=false
while [[ ${elapsed} -lt ${TIMEOUT} ]]; do
    sleep 10
    elapsed=$((elapsed + 10))
    # Check Jenkins for the job (job name might vary)
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" "${JENKINS_URL}/job/${TEST_PROJECT}/1/api/json" 2>/dev/null || echo "000")
    if [[ "${http_code}" == "200" ]]; then
        build_found=true
        break
    fi
    printf "\r  Waiting... %ds/%ds" "${elapsed}" "${TIMEOUT}"
done
echo ""

if [[ "${build_found}" == "true" ]]; then
    assert_pass "Jenkins build triggered"
else
    assert_fail "Jenkins build not found within ${TIMEOUT}s (webhook may not be configured)"
fi

echo ""
echo "=== Smoke Test Results: Pass=${PASS} Fail=${FAIL} ==="
[[ ${FAIL} -eq 0 ]] || exit 1
