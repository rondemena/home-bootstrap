#!/usr/bin/env bash
# End-to-end integration test for primary CI pipeline flow (US4 - T047)
# Usage: ./tests/e2e/test_ci_pipeline.sh
#
# Flow: GitLab repo -> push commit with Jenkinsfile -> Jenkins build triggers ->
#       container image published to Harbor -> cleanup
#
# Required environment variables:
#   GITLAB_TOKEN    - GitLab admin personal access token (api scope)
#
# Optional environment variables:
#   INGRESS_DOMAIN  - Base domain (default: apps.home.lab)
#   GITLAB_USER     - GitLab username for push (default: root)
#   HARBOR_USER     - Harbor admin username (default: admin)
#   HARBOR_PASS     - Harbor admin password (default: Harbor12345)
#   JENKINS_USER    - Jenkins admin username (default: admin)
#   JENKINS_TOKEN   - Jenkins API token (default: reads from env)
#   BUILD_TIMEOUT   - Max seconds to wait for Jenkins build (default: 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export REPO_ROOT  # available to child processes

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
INGRESS_DOMAIN="${INGRESS_DOMAIN:-apps.home.lab}"
GITLAB_URL="https://gitlab.${INGRESS_DOMAIN}"
JENKINS_URL="https://jenkins.${INGRESS_DOMAIN}"
HARBOR_URL="https://harbor.${INGRESS_DOMAIN}"

GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_USER="${GITLAB_USER:-root}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_TOKEN="${JENKINS_TOKEN:-}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-120}"

# Test artifacts (for cleanup)
TEST_PROJECT_NAME="ci-pipeline-test-$(date +%s)"
HARBOR_PROJECT="library"
IMAGE_NAME="${TEST_PROJECT_NAME}"
WORK_DIR=""
GITLAB_PROJECT_ID=""

# ---------------------------------------------------------------------------
# Cleanup handler -- runs on EXIT regardless of success/failure
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    echo ""
    log_section "Cleanup"

    # Delete GitLab project
    if [[ -n "${GITLAB_PROJECT_ID}" && -n "${GITLAB_TOKEN}" ]]; then
        log_info "Deleting GitLab project ${TEST_PROJECT_NAME} (ID: ${GITLAB_PROJECT_ID})..."
        local delete_code
        delete_code=$(curl -sk -o /dev/null -w '%{http_code}' \
            -X DELETE \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/projects/${GITLAB_PROJECT_ID}" 2>/dev/null) || true
        if [[ "${delete_code}" == "202" || "${delete_code}" == "204" ]]; then
            log_info "GitLab project deleted (HTTP ${delete_code})"
        else
            log_info "GitLab project deletion returned HTTP ${delete_code} (may need manual cleanup)"
        fi
    fi

    # Delete Harbor image
    if [[ -n "${HARBOR_USER}" ]]; then
        log_info "Deleting Harbor image ${HARBOR_PROJECT}/${IMAGE_NAME}..."
        # List tags first, then delete the repository
        local harbor_delete_code
        harbor_delete_code=$(curl -sk -o /dev/null -w '%{http_code}' \
            -X DELETE \
            -u "${HARBOR_USER}:${HARBOR_PASS}" \
            "${HARBOR_URL}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${IMAGE_NAME}" 2>/dev/null) || true
        if [[ "${harbor_delete_code}" == "200" || "${harbor_delete_code}" == "404" ]]; then
            log_info "Harbor image cleaned up (HTTP ${harbor_delete_code})"
        else
            log_info "Harbor image cleanup returned HTTP ${harbor_delete_code} (may need manual cleanup)"
        fi
    fi

    # Remove temporary working directory
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        log_info "Removing temporary directory ${WORK_DIR}"
        rm -rf "${WORK_DIR}"
    fi

    log_info "Cleanup complete"
    exit "${exit_code}"
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
preflight() {
    log_section "Preflight Checks"

    if [[ -z "${GITLAB_TOKEN}" ]]; then
        log_fail "GITLAB_TOKEN environment variable is required"
        echo ""
        echo "  Export a GitLab admin personal access token with 'api' scope:"
        echo "    export GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx"
        echo ""
        exit 1
    fi

    # Verify required tools
    for cmd in curl git jq; do
        if command -v "${cmd}" > /dev/null 2>&1; then
            log_pass "${cmd} available"
        else
            log_fail "${cmd} is required but not found"
            exit 1
        fi
    done

    # Verify GitLab is reachable
    local gl_code
    gl_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/version" 2>/dev/null) || true
    if [[ "${gl_code}" == "200" ]]; then
        log_pass "GitLab API reachable"
    else
        log_fail "GitLab API not reachable (HTTP ${gl_code})"
        exit 1
    fi

    # Verify Jenkins is reachable
    local jk_code
    jk_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 \
        "${JENKINS_URL}/login" 2>/dev/null) || true
    if [[ "${jk_code}" == "200" ]]; then
        log_pass "Jenkins reachable"
    else
        log_fail "Jenkins not reachable (HTTP ${jk_code})"
        exit 1
    fi

    # Verify Harbor is reachable
    local hb_code
    hb_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 \
        "${HARBOR_URL}/api/v2.0/health" 2>/dev/null) || true
    if [[ "${hb_code}" == "200" ]]; then
        log_pass "Harbor API reachable"
    else
        log_fail "Harbor API not reachable (HTTP ${hb_code})"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Create a test repository in GitLab via API
# ---------------------------------------------------------------------------
create_gitlab_project() {
    log_section "Step 1: Create GitLab Test Repository"

    log_info "Creating project '${TEST_PROJECT_NAME}' in GitLab..."

    local response
    response=$(curl -sk \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${TEST_PROJECT_NAME}\",
            \"visibility\": \"internal\",
            \"initialize_with_readme\": true
        }" \
        "${GITLAB_URL}/api/v4/projects" 2>/dev/null)

    GITLAB_PROJECT_ID=$(echo "${response}" | jq -r '.id // empty' 2>/dev/null)

    if [[ -n "${GITLAB_PROJECT_ID}" && "${GITLAB_PROJECT_ID}" != "null" ]]; then
        log_pass "GitLab project created (ID: ${GITLAB_PROJECT_ID})"
    else
        local error_msg
        error_msg=$(echo "${response}" | jq -r '.message // .error // "unknown error"' 2>/dev/null)
        log_fail "Failed to create GitLab project: ${error_msg}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Add a Jenkinsfile and Dockerfile, then push a commit
# ---------------------------------------------------------------------------
push_test_commit() {
    log_section "Step 2: Push Test Commit with Jenkinsfile"

    WORK_DIR=$(mktemp -d "/tmp/ci-pipeline-test.XXXXXX")
    log_info "Working directory: ${WORK_DIR}"

    # Clone the newly created repo
    local clone_url="https://oauth2:${GITLAB_TOKEN}@gitlab.${INGRESS_DOMAIN}/${GITLAB_USER}/${TEST_PROJECT_NAME}.git"

    log_info "Cloning repository..."
    if GIT_SSL_NO_VERIFY=true git clone "${clone_url}" "${WORK_DIR}/repo" > /dev/null 2>&1; then
        log_pass "Repository cloned"
    else
        log_fail "Failed to clone repository"
        exit 1
    fi

    # Create a minimal Dockerfile
    cat > "${WORK_DIR}/repo/Dockerfile" << 'DOCKERFILE'
FROM alpine:3.19
RUN echo "CI pipeline test image" > /BUILD_INFO
CMD ["cat", "/BUILD_INFO"]
DOCKERFILE

    # Create a Jenkinsfile that builds and pushes to Harbor
    cat > "${WORK_DIR}/repo/Jenkinsfile" << JENKINSFILE
pipeline {
    agent {
        kubernetes {
            defaultContainer 'kaniko'
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command: ['sleep']
    args: ['3600']
    volumeMounts:
    - name: kaniko-secret
      mountPath: /kaniko/.docker
  volumes:
  - name: kaniko-secret
    secret:
      secretName: harbor-registry-credentials
      items:
      - key: .dockerconfigjson
        path: config.json
"""
        }
    }
    stages {
        stage('Build and Push') {
            steps {
                container('kaniko') {
                    sh """
                        /kaniko/executor \\
                            --context=\${WORKSPACE} \\
                            --destination=harbor.${INGRESS_DOMAIN}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest \\
                            --skip-tls-verify
                    """
                }
            }
        }
    }
}
JENKINSFILE

    # Commit and push
    cd "${WORK_DIR}/repo"
    git config user.email "ci-test@${INGRESS_DOMAIN}"
    git config user.name "CI Pipeline Test"
    git add Dockerfile Jenkinsfile
    git commit -m "Add Jenkinsfile and Dockerfile for CI pipeline test" > /dev/null 2>&1

    log_info "Pushing commit to GitLab..."
    if GIT_SSL_NO_VERIFY=true git push origin main > /dev/null 2>&1; then
        log_pass "Test commit pushed to GitLab"
    else
        # Some GitLab setups use 'master' as default branch
        if GIT_SSL_NO_VERIFY=true git push origin master > /dev/null 2>&1; then
            log_pass "Test commit pushed to GitLab (master branch)"
        else
            log_fail "Failed to push commit to GitLab"
            exit 1
        fi
    fi

    cd "${SCRIPT_DIR}"
}

# ---------------------------------------------------------------------------
# Step 3: Wait for Jenkins build to trigger
# ---------------------------------------------------------------------------
wait_for_jenkins_build() {
    log_section "Step 3: Wait for Jenkins Build"

    # Jenkins job naming convention: folder/project or just project name
    # Adjust the job path based on your Jenkins-GitLab integration config
    local job_name="${TEST_PROJECT_NAME}"
    local job_path="${GITLAB_USER}/${TEST_PROJECT_NAME}"

    # Build Jenkins auth args if credentials are available
    local auth_args=()
    if [[ -n "${JENKINS_USER}" && -n "${JENKINS_TOKEN}" ]]; then
        auth_args=(-u "${JENKINS_USER}:${JENKINS_TOKEN}")
    fi

    log_info "Waiting up to ${BUILD_TIMEOUT}s for Jenkins build to appear..."

    local elapsed=0
    local poll_interval=5
    local build_url=""
    local build_found=false

    while [[ ${elapsed} -lt ${BUILD_TIMEOUT} ]]; do
        # Try multiple possible job paths (Jenkins folder structures vary)
        for try_path in "${job_name}" "${job_path}" "${GITLAB_USER}%2F${TEST_PROJECT_NAME}"; do
            local api_url="${JENKINS_URL}/job/${try_path}/api/json"
            local response
            response=$(curl -sk "${auth_args[@]}" \
                --connect-timeout 5 \
                "${api_url}" 2>/dev/null) || true

            local last_build
            last_build=$(echo "${response}" | jq -r '.lastBuild.url // empty' 2>/dev/null)

            if [[ -n "${last_build}" ]]; then
                build_url="${last_build}"
                build_found=true
                break 2
            fi
        done

        sleep "${poll_interval}"
        elapsed=$((elapsed + poll_interval))
        log_info "Waiting... (${elapsed}/${BUILD_TIMEOUT}s)"
    done

    if [[ "${build_found}" == "true" ]]; then
        log_pass "Jenkins build triggered: ${build_url}"
    else
        log_fail "Jenkins build did not trigger within ${BUILD_TIMEOUT}s"
        return 0
    fi

    # Wait for the build to complete
    log_info "Waiting for build to complete..."
    local build_elapsed=0
    local build_complete=false
    local build_result=""

    while [[ ${build_elapsed} -lt ${BUILD_TIMEOUT} ]]; do
        local build_response
        build_response=$(curl -sk "${auth_args[@]}" \
            --connect-timeout 5 \
            "${build_url}api/json" 2>/dev/null) || true

        local building
        building=$(echo "${build_response}" | jq -r '.building // true' 2>/dev/null)

        if [[ "${building}" == "false" ]]; then
            build_result=$(echo "${build_response}" | jq -r '.result // "UNKNOWN"' 2>/dev/null)
            build_complete=true
            break
        fi

        sleep "${poll_interval}"
        build_elapsed=$((build_elapsed + poll_interval))
        log_info "Build in progress... (${build_elapsed}/${BUILD_TIMEOUT}s)"
    done

    if [[ "${build_complete}" == "true" ]]; then
        if [[ "${build_result}" == "SUCCESS" ]]; then
            log_pass "Jenkins build completed: ${build_result}"
        else
            log_fail "Jenkins build completed with result: ${build_result}"
        fi
    else
        log_fail "Jenkins build did not complete within ${BUILD_TIMEOUT}s"
    fi
}

# ---------------------------------------------------------------------------
# Step 4: Verify container image exists in Harbor
# ---------------------------------------------------------------------------
verify_harbor_image() {
    log_section "Step 4: Verify Harbor Image"

    log_info "Checking Harbor for image ${HARBOR_PROJECT}/${IMAGE_NAME}..."

    local response
    response=$(curl -sk \
        -u "${HARBOR_USER}:${HARBOR_PASS}" \
        "${HARBOR_URL}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${IMAGE_NAME}" 2>/dev/null)

    local repo_name
    repo_name=$(echo "${response}" | jq -r '.name // empty' 2>/dev/null)

    if [[ -n "${repo_name}" && "${repo_name}" != "null" ]]; then
        log_pass "Image found in Harbor: ${repo_name}"
    else
        log_fail "Image not found in Harbor: ${HARBOR_PROJECT}/${IMAGE_NAME}"
        return 0
    fi

    # Verify the 'latest' tag exists
    local tags_response
    tags_response=$(curl -sk \
        -u "${HARBOR_USER}:${HARBOR_PASS}" \
        "${HARBOR_URL}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${IMAGE_NAME}/artifacts?page=1&page_size=10" 2>/dev/null)

    local artifact_count
    artifact_count=$(echo "${tags_response}" | jq 'length // 0' 2>/dev/null)

    if [[ "${artifact_count}" -gt 0 ]]; then
        log_pass "Harbor image has ${artifact_count} artifact(s)"
    else
        log_fail "Harbor image has no artifacts"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "============================================"
echo "  CI Pipeline Integration Test (US4 - T047)"
echo "============================================"
echo ""
echo "  GitLab:  ${GITLAB_URL}"
echo "  Jenkins: ${JENKINS_URL}"
echo "  Harbor:  ${HARBOR_URL}"
echo "  Project: ${TEST_PROJECT_NAME}"

preflight
create_gitlab_project
push_test_commit
wait_for_jenkins_build
verify_harbor_image

echo ""
echo "============================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} (${TOTAL} total)"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
