# home-bootstrap Makefile
# Bare-metal SDLC bootstrap: Proxmox VMs -> k3s -> SDLC toolchain
#
# Usage:
#   make help            Show all available targets
#   make bootstrap       Run full bootstrap sequence
#   make lint            Run all linters

# ---------------------------------------------------------------------------
# Path variables
# ---------------------------------------------------------------------------
ANSIBLE_DIR  := code/ansible
TOFU_DIR     := code/tofu
K8S_DIR      := code/k8s
SCRIPTS_DIR  := code/scripts
TESTS_DIR    := tests

# ---------------------------------------------------------------------------
# Tool overrides (set via env or CLI)
# ---------------------------------------------------------------------------
ANSIBLE_PLAYBOOK ?= ansible-playbook
ANSIBLE_LINT     ?= ansible-lint
TOFU             ?= tofu
TFLINT           ?= tflint
YAMLLINT         ?= yamllint
SHELLCHECK       ?= shellcheck
KUBECTL          ?= kubectl
HELM             ?= helm

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# PHONY declarations
# ---------------------------------------------------------------------------
.PHONY: help bootstrap \
        provision-server configure-proxmox \
        plan-vms provision-vms \
        bootstrap-k3s deploy-infra deploy-apps \
        lint \
        test-ilo test-proxmox test-proxmox-auth test-vms \
        test-k3s test-infra test-apps test-e2e \
        health-check check-ilo-license \
        destroy-vms destroy-all

# ---------------------------------------------------------------------------
# help - list all targets with descriptions
# ---------------------------------------------------------------------------
## help: Show this help message (default target)
help:
	@printf "\\n  home-bootstrap -- bare-metal SDLC bootstrap\\n\\n"
	@printf "  %-25s %s\\n" "Target" "Description"
	@printf "  %-25s %s\\n" "------" "-----------"
	@grep -E '^## ' $(MAKEFILE_LIST) | \
		sed 's/^## //' | \
		awk -F: '{printf "  %-25s %s\n", $$1, $$2}'
	@printf "\\n"

# ===========================================================================
# Layer 1 -- Bare Metal Provisioning
# ===========================================================================

## provision-server: Provision bare-metal server via iLO (HOST= required)
provision-server:
ifndef HOST
	$(error HOST is required. Usage: make provision-server HOST=<ilo-ip>)
endif
	cd $(ANSIBLE_DIR) && $(ANSIBLE_PLAYBOOK) playbooks/00-ilo-provision.yml \
		-e "ilo_host_filter=$(HOST)"

## configure-proxmox: Configure Proxmox host (storage, network, repos, API token)
configure-proxmox:
	cd $(ANSIBLE_DIR) && $(ANSIBLE_PLAYBOOK) playbooks/01-proxmox-configure.yml
	cd $(ANSIBLE_DIR) && $(ANSIBLE_PLAYBOOK) playbooks/02-cloud-image-template.yml

# ===========================================================================
# Layer 2 -- VM Provisioning (OpenTofu)
# ===========================================================================

## plan-vms: Show VM provisioning plan (dry run)
plan-vms:
	cd $(TOFU_DIR)/environments/prod && $(TOFU) plan

## provision-vms: Provision VMs on Proxmox via OpenTofu
provision-vms:
	cd $(TOFU_DIR)/environments/prod && $(TOFU) apply -auto-approve

# ===========================================================================
# Layer 3 -- k3s Cluster Bootstrap
# ===========================================================================

## bootstrap-k3s: Install and configure k3s cluster
bootstrap-k3s:
	cd $(ANSIBLE_DIR) && $(ANSIBLE_PLAYBOOK) playbooks/03-k3s-install.yml

## deploy-infra: Deploy infrastructure services (MetalLB, Longhorn, cert-manager, etc.)
deploy-infra:
	cd $(ANSIBLE_DIR) && $(ANSIBLE_PLAYBOOK) playbooks/04-k3s-post-install.yml

# ===========================================================================
# Layer 4 -- SDLC Application Deployment
# ===========================================================================

## deploy-apps: Deploy SDLC applications via ArgoCD
deploy-apps:
	cd $(ANSIBLE_DIR) && $(ANSIBLE_PLAYBOOK) playbooks/05-argocd-install.yml
	$(KUBECTL) apply -f $(K8S_DIR)/argocd/applications/
	@echo "Waiting for ArgoCD applications to sync..."
	@sleep 30
	$(KUBECTL) -n argocd get applications

# ===========================================================================
# Full Bootstrap
# ===========================================================================

## bootstrap: Run ALL layers sequentially (full stack bootstrap)
bootstrap: configure-proxmox plan-vms provision-vms bootstrap-k3s deploy-infra deploy-apps
	@echo "Bootstrap complete. Run 'make test-e2e' to validate."

# ===========================================================================
# Linting
# ===========================================================================

## lint: Run all linters (ansible-lint, yamllint, tflint, tofu validate, shellcheck)
lint:
	@echo "--- ansible-lint ---"
	cd $(ANSIBLE_DIR) && $(ANSIBLE_LINT) || true
	@echo ""
	@echo "--- yamllint ---"
	$(YAMLLINT) -c .yamllint.yml $(ANSIBLE_DIR)/ $(K8S_DIR)/ || true
	@echo ""
	@echo "--- tflint ---"
	cd $(TOFU_DIR) && $(TFLINT) --config .tflint.hcl || true
	@echo ""
	@echo "--- tofu validate ---"
	cd $(TOFU_DIR)/environments/prod && $(TOFU) validate || true
	@echo ""
	@echo "--- shellcheck ---"
	$(SHELLCHECK) $(SCRIPTS_DIR)/*.sh || true

# ===========================================================================
# Testing
# ===========================================================================

## test-ilo: Run iLO integration tests
test-ilo:
	$(TESTS_DIR)/e2e/test_ilo_provision.sh $(HOST)

## test-proxmox: Test Proxmox host configuration
test-proxmox:
	@echo "Testing Proxmox API..."
	@curl -sk --connect-timeout 5 "https://192.168.2.11:8006/api2/json/version" | jq .data.version

## test-proxmox-auth: Test Proxmox API authentication
test-proxmox-auth:
	@echo "Testing Proxmox API auth..."
	@curl -sk --connect-timeout 5 -H "Authorization: PVEAPIToken=$${PVE_API_TOKEN}" \
		"https://192.168.2.11:8006/api2/json/nodes" | jq '.data[].node'

## test-vms: Run VM integration tests
test-vms:
	$(TESTS_DIR)/e2e/test_vm_provision.sh

## test-k3s: Run k3s smoke tests
test-k3s:
	$(TESTS_DIR)/k8s/smoke/test_cluster.sh

## test-infra: Run infrastructure service tests (MetalLB, Longhorn, etc.)
test-infra:
	$(TESTS_DIR)/k8s/smoke/test_infra.sh

## test-apps: Run SDLC application health checks
test-apps:
	$(TESTS_DIR)/k8s/smoke/test_sdlc_health.sh

## test-e2e: Run full end-to-end test suite
test-e2e:
	$(SCRIPTS_DIR)/test-e2e.sh

# ===========================================================================
# Operations
# ===========================================================================

## health-check: Check all service health endpoints
health-check:
	$(TESTS_DIR)/k8s/smoke/test_sdlc_health.sh
	@echo ""
	@echo "--- Observability Stack ---"
	$(TESTS_DIR)/e2e/test_observability.sh

## check-ilo-license: Check iLO license level (HOST= required)
check-ilo-license:
ifndef HOST
	$(error HOST is required. Usage: make check-ilo-license HOST=<ilo-ip>)
endif
	@echo "Checking iLO license at $(HOST)..."
	@curl -sk -u "$${ILO_USER:-ansible-svc}:$${ILO_PASS}" \
		"https://$(HOST)/redfish/v1/Managers/1/LicenseService/1/" \
		| jq '{License: .License, LicenseType: .LicenseType, Confirmation: .Confirmation.Code}'

# ===========================================================================
# Teardown (use with caution)
# ===========================================================================

## destroy-vms: Destroy all VMs (keeps Proxmox)
destroy-vms:
	cd $(TOFU_DIR)/environments/prod && $(TOFU) destroy -auto-approve

## destroy-all: Destroy ALL resources (VMs + k3s cluster) -- DANGEROUS
destroy-all:
	@printf "\\n  !!! WARNING: This will destroy ALL VMs and the k3s cluster !!!\\n"
	@printf "  Press Ctrl+C within 10 seconds to abort...\\n\\n"
	@sleep 10
	cd $(TOFU_DIR)/environments/prod && $(TOFU) destroy -auto-approve
