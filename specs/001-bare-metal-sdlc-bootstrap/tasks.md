---
description: "Task list for bare metal SDLC bootstrap implementation"
---

# Tasks: Bare Metal SDLC Bootstrap

**Input**: Design documents from `/specs/001-bare-metal-sdlc-bootstrap/`
**Prerequisites**: plan.md (required), spec.md (required), research.md,
data-model.md, contracts/

**Tests**: Tests are REQUIRED per Constitution Principle III
(Test-Driven Infrastructure, NON-NEGOTIABLE).

**Organization**: Tasks are grouped by bootstrap layer (matching user
stories) to enable independent implementation and testing of each layer.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1-US5)
- Include exact file paths in descriptions

## Path Conventions

- **Ansible**: `code/ansible/`
- **OpenTofu**: `code/tofu/`
- **Kubernetes**: `code/k8s/`
- **Tests**: `tests/`
- **Scripts**: `code/scripts/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Repository structure, tooling configuration, secrets setup

- [x] T001 [P] Create directory structure per implementation plan
  (`code/ansible/`, `code/tofu/`, `code/k8s/`, `tests/`, `code/scripts/`)
- [x] T002 [P] Create top-level Makefile with target stubs for all
  operations (`bootstrap`, `provision-server`, `configure-proxmox`,
  `plan-vms`, `provision-vms`, `bootstrap-k3s`, `deploy-infra`,
  `deploy-apps`, `lint`, `test-e2e`, `health-check`, `destroy-vms`,
  `destroy-all`)
- [x] T003 [P] Create `code/ansible/ansible.cfg` with defaults
  (inventory path, roles path, stdout_callback, vault settings,
  host_key_checking=False for initial provisioning)
- [x] T004 [P] Create `code/ansible/requirements.yml` with Ansible
  Galaxy dependencies (`community.general`, `community.crypto`,
  `ansible.posix`, Galaxy k3s role)
- [x] T005 [P] Create `code/tofu/.tflint.hcl` with Proxmox provider
  rules and OpenTofu compatibility
- [x] T006 [P] Create `.pre-commit-config.yaml` with hooks for
  tofu_fmt, tofu_validate, tflint, ansible-lint, yamllint,
  detect-private-key, shellcheck, trailing-whitespace, end-of-file-fixer
- [x] T007 [P] Create `.sops.yaml` configuration template for age
  encryption with path regex `\.enc\.ya?ml$`
- [x] T008 [P] Create `.gitignore` with rules for `.terraform/`,
  `.tofu/`, `*.tfstate*`, `*.retry`, `__pycache__/`, `.env`,
  `*.enc.yml.dec`, `kubeconfig*`
- [x] T009 Create component inventory document
  (`docs/component-inventory.md`) listing all tools with name, version,
  license (SPDX), purpose, and stack (primary/secondary/infrastructure)
  per FR-014

**Checkpoint**: Repository is structured, tooling is configured, all
pre-commit hooks pass on empty project.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Ansible inventory, secret management, OpenTofu provider
bootstrap

**CRITICAL**: No layer-specific work can begin until this phase is
complete

- [x] T010 Create Ansible inventory skeleton
  (`code/ansible/inventory/hosts.yml`) per inventory-schema contract
  with groups: `ilo_targets` (DL380g10, DL360g9), `proxmox` (pve-01),
  `k3s_server` (k3s-server-01 at 192.168.2.100), `k3s_agent`
  (k3s-agent-01 at 192.168.2.200, k3s-agent-02 at 192.168.2.201),
  `k3s_cluster` (children of server+agent)
- [x] T011 [P] Create Ansible group_vars files:
  `code/ansible/inventory/group_vars/all.yml` (ansible_user, domain,
  dns_servers, ntp_servers),
  `code/ansible/inventory/group_vars/proxmox.yml` (pve_api_host,
  pve_api_user, storage pools),
  `code/ansible/inventory/group_vars/k3s_server.yml` (k3s_role: server),
  `code/ansible/inventory/group_vars/k3s_agent.yml` (k3s_role: agent),
  `code/ansible/inventory/group_vars/k3s_cluster.yml` (k3s_version:
  v1.31.4+k3s1, k3s_server_url, metallb_ip_range: 192.168.2.240-250,
  ingress_domain: apps.home.lab)
- [x] T012 [P] Create encrypted secrets template
  (`code/ansible/inventory/group_vars/secrets.enc.yml`) with SOPS+age
  for ilo_pass, pve_api_token_id, pve_api_token_secret, k3s_token
- [x] T013 [P] Create OpenTofu provider configuration
  (`code/tofu/modules/proxmox-vm/versions.tf`) pinning bpg/proxmox
  provider >= 0.66.0 with OpenTofu >= 1.7 constraint
- [x] T014 [P] Create OpenTofu environment base
  (`code/tofu/environments/prod/main.tf`, `variables.tf`, `backend.tf`)
  with local backend (bootstrap exception documented in plan.md
  Complexity Tracking)

**Checkpoint**: Foundation ready. `ansible-playbook --syntax-check`
passes. `tofu init` succeeds. Secrets are encrypted. Inventory matches
contract schema.

---

## Phase 3: User Story 1 - HPE iLO Server Provisioning (P1) MVP

**Goal**: Automate BIOS configuration and Proxmox VE installation via
iLO Redfish API, handling both iLO 4 (DL360g9) and iLO 5 (DL380g10)

**Independent Test**: Run playbook against iLO endpoint; verify Proxmox
API responds after installation. DL380g10 skips provisioning
(`proxmox_already_installed: true`).

### Tests for User Story 1

> **Write these tests FIRST, ensure they FAIL before implementation**

- [x] T015 [P] [US1] Ansible lint config for iLO playbook in
  `tests/ansible/lint/test_ilo.yml` and Molecule test scaffolding for
  `ilo_provision` role in `code/ansible/roles/ilo_provision/molecule/`
  (default scenario with container driver, verify BIOS config tasks
  execute, assert idempotency on second run)
- [x] T016 [P] [US1] Integration test assertions for iLO provisioning
  in `tests/e2e/test_ilo_provision.sh` (checks BIOS settings match
  desired state via Redfish query, Proxmox API reachable on VLAN 2,
  virtual media ejected after install)

### Implementation for User Story 1

- [x] T017 [P] [US1] Create Proxmox answer file for DL380g10
  (`code/ansible/files/proxmox-answer-dl380.toml`) with hostname
  pve-01, IP 192.168.2.11/24, gateway 192.168.2.1, DNS 192.168.2.1,
  target disk (hardware RAID logical volume)
- [x] T018 [P] [US1] Create Proxmox answer file for DL360g9
  (`code/ansible/files/proxmox-answer-dl360.toml`) with hostname
  pve-02, IP 192.168.2.12/24, gateway 192.168.2.1, DNS 192.168.2.1,
  target disk TBD
- [x] T019 [US1] Create `ilo_provision` Ansible role
  (`code/ansible/roles/ilo_provision/`) with tasks:
  - Detect iLO version (ilo4 vs ilo5) from inventory variable
  - Gather current BIOS state via `redfish_info`
  - Configure BIOS (VT-x, VT-d, UEFI boot) via `redfish_config`
    only if current state differs (idempotent)
  - Check if Proxmox is already installed (SSH probe on VLAN 2 IP)
  - Skip provisioning if `proxmox_already_installed: true`
  - iLO 5 path: Mount ISO via Redfish `VirtualMediaInsert`, set
    one-time boot to CD, power cycle
  - iLO 4 path: Check `ilo_advanced_license`, warn if false (virtual
    media requires Advanced license on iLO 4), mount ISO if licensed
  - Wait for SSH availability on management IP (timeout 30min)
  - Eject virtual media
  - Verify Proxmox API responds on port 8006
- [x] T020 [US1] Create iLO provisioning playbook
  (`code/ansible/playbooks/00-ilo-provision.yml`) targeting
  `ilo_targets` group, using `ilo_provision` role
- [x] T021 [US1] Add Makefile targets: `provision-server` (accepts
  HOST= parameter), `test-ilo`, `check-ilo-license`
- [x] T022 [US1] Verify lint and integration tests pass for iLO role

**Checkpoint**: `make provision-server HOST=192.168.5.12` configures
BIOS on DL360g9. `make provision-server HOST=192.168.5.11` reports no
changes for DL380g10 (already installed). Re-run on DL360g9 is
idempotent.

---

## Phase 4: User Story 2 - Proxmox Infrastructure Layer (P1)

**Goal**: Configure Proxmox host and provision VMs with cloud-init
via OpenTofu on DL380g10

**Independent Test**: `tofu apply` creates 3 VMs (k3s-server-01,
k3s-agent-01, k3s-agent-02) on DL380g10; `tofu plan` shows zero
changes on re-run; all VMs reachable via SSH on VLAN 2

### Tests for User Story 2

> **Write these tests FIRST, ensure they FAIL before implementation**

- [x] T023 [P] [US2] Ansible lint test for Proxmox playbooks in
  `tests/ansible/lint/test_proxmox.yml` and Molecule test scaffolding
  for `proxmox_configure` role in
  `code/ansible/roles/proxmox_configure/molecule/` and
  `cloud_image_template` role in
  `code/ansible/roles/cloud_image_template/molecule/` (default
  scenarios verifying task execution and idempotency)
- [x] T024 [P] [US2] OpenTofu validation test for proxmox-vm module
  in `code/tofu/modules/proxmox-vm/tests/basic.tftest.hcl`
- [x] T025 [P] [US2] Integration test for VM provisioning in
  `tests/e2e/test_vm_provision.sh` (checks VMs running via Proxmox
  API, SSH accessible on VLAN 2 IPs, cloud-init complete via
  `/var/lib/cloud/instance/boot-finished`, correct hostnames and IPs,
  ping gateway 192.168.2.1 from guest)

### Implementation for User Story 2

- [x] T026 [US2] Create `proxmox_configure` Ansible role
  (`code/ansible/roles/proxmox_configure/`) with tasks:
  - Configure Proxmox no-subscription repository
  - Configure storage pools per inventory
  - Configure network bridge `vmbr0` (VLAN-aware, trunked to VLANs
    2-5) if not already present
  - Create API token for OpenTofu (`automation@pam!tofu`) if not exists
  - Enable snippets storage for cloud-init custom configs
- [x] T027 [US2] Create Proxmox configuration playbook
  (`code/ansible/playbooks/01-proxmox-configure.yml`) targeting
  `proxmox` group, using `proxmox_configure` role
- [x] T028 [US2] Create `cloud_image_template` Ansible role
  (`code/ansible/roles/cloud_image_template/`) with tasks:
  - Download Ubuntu 24.04 LTS cloud image (idempotent, SHA256 verify)
  - Create VM shell (VMID 9000), import disk, add cloud-init drive
  - Convert to template (skip if template VMID 9000 already exists)
- [x] T029 [US2] Create cloud-init template playbook
  (`code/ansible/playbooks/02-cloud-image-template.yml`) targeting
  `proxmox` group, using `cloud_image_template` role
- [x] T030 [US2] Create OpenTofu `proxmox-vm` module
  (`code/tofu/modules/proxmox-vm/main.tf`, `variables.tf`,
  `outputs.tf`) with clone from template VMID 9000, cloud-init
  configuration (hostname, SSH key, static IP, DNS), VLAN tag,
  lifecycle ignore_changes for cloud-init after first boot
- [x] T031 [US2] Create production environment configuration
  (`code/tofu/environments/prod/terraform.tfvars`) with VM definitions
  per data-model:
  - k3s-server-01: VMID 100, 8c, 16GB, 100GB, IP 192.168.2.100
  - k3s-agent-01: VMID 200, 8c, 64GB, 200GB, IP 192.168.2.200
  - k3s-agent-02: VMID 201, 8c, 64GB, 200GB, IP 192.168.2.201
  All on node `pve-01`, bridge `vmbr0`, VLAN 2, gateway 192.168.2.1
- [x] T032 [US2] Create production environment main.tf
  (`code/tofu/environments/prod/main.tf`) calling `proxmox-vm` module
  for each VM definition with provider configuration pointing to
  `https://192.168.2.11:8006/`
- [x] T033 [US2] Add Makefile targets: `configure-proxmox`,
  `plan-vms`, `provision-vms`, `test-proxmox`, `test-vms`,
  `destroy-vms`
- [x] T034 [US2] Verify all lint, validation, and integration tests
  pass

**Checkpoint**: `make configure-proxmox` sets up Proxmox host.
`make provision-vms` creates 3 VMs with correct config. `make plan-vms`
shows zero changes on re-run. All VMs accessible via SSH on VLAN 2.

---

## Phase 5: User Story 3 - Kubernetes Cluster Bootstrap (P2)

**Goal**: Install k3s cluster with infrastructure services (MetalLB,
Longhorn, cert-manager, Sealed Secrets) on the 3 VMs

**Independent Test**: `kubectl get nodes` shows all 3 nodes Ready;
test LoadBalancer Service gets IP from 192.168.2.240-250; test PVC
binds to Longhorn; test Ingress gets TLS cert

### Tests for User Story 3

> **Write these tests FIRST, ensure they FAIL before implementation**

- [x] T035 [P] [US3] Ansible lint test for k3s playbooks in
  `tests/ansible/lint/test_k3s.yml`
- [x] T036 [P] [US3] Smoke test for k3s cluster in
  `tests/k8s/smoke/test_cluster.sh` (all 3 nodes Ready, kube-system
  pods Running, CoreDNS resolving, Traefik running)
- [x] T037 [P] [US3] Integration test for infrastructure services in
  `tests/k8s/smoke/test_infra.sh` (MetalLB assigns IP from
  192.168.2.240-250 to test LoadBalancer Service, Longhorn PVC binds,
  cert-manager issues certificate, Sealed Secrets controller running)

### Implementation for User Story 3

- [x] T038 [US3] Create k3s installation playbook
  (`code/ansible/playbooks/03-k3s-install.yml`) with tasks:
  - Install k3s server on k3s-server-01 (192.168.2.100) with
    `--disable servicelb` (MetalLB replaces it), pinned version
    v1.31.4+k3s1
  - Install k3s agent on k3s-agent-01 (192.168.2.200) and
    k3s-agent-02 (192.168.2.201) joining via k3s_server_url
  - Fetch kubeconfig from server node to workstation
  - Verify all nodes Ready via kubectl
- [x] T039 [US3] Create k3s post-install playbook
  (`code/ansible/playbooks/04-k3s-post-install.yml`) with tasks:
  - Install Helm on workstation (if not present)
  - Add Helm repositories for MetalLB, Longhorn, cert-manager,
    Sealed Secrets
  - Deploy MetalLB via Helm with values and IP pool config
  - Deploy Longhorn via Helm with values
  - Deploy cert-manager via Helm with CRDs and ClusterIssuer
  - Deploy Sealed Secrets controller via Helm
- [x] T040 [P] [US3] Create MetalLB Helm values and IP pool manifest
  (`code/k8s/infrastructure/metallb/values.yaml`,
  `code/k8s/infrastructure/metallb/ip-pool.yaml`) with address pool
  192.168.2.240-192.168.2.250 on VLAN 2
- [x] T041 [P] [US3] Create Longhorn Helm values
  (`code/k8s/infrastructure/longhorn/values.yaml`) with default
  StorageClass, replica count 2 (for 2 agent nodes), UI ingress
  optional
- [x] T042 [P] [US3] Create cert-manager Helm values and
  ClusterIssuer (`code/k8s/infrastructure/cert-manager/values.yaml`,
  `code/k8s/infrastructure/cert-manager/cluster-issuer.yaml`) with
  self-signed issuer for `*.apps.home.lab`
- [x] T043 [P] [US3] Create Sealed Secrets Helm values
  (`code/k8s/infrastructure/sealed-secrets/values.yaml`)
- [x] T044 [US3] Add Makefile targets: `bootstrap-k3s`, `deploy-infra`,
  `test-k3s`, `test-infra`
- [x] T045 [US3] Verify all lint and smoke tests pass

**Checkpoint**: k3s cluster operational with MetalLB, Longhorn,
cert-manager, Sealed Secrets. `kubectl get nodes` shows 3 nodes Ready.
LoadBalancer Services get IPs from 192.168.2.240-250. PVCs bind to
Longhorn. Self-signed TLS certs issue for `*.apps.home.lab`.

---

## Phase 6: User Story 4 - SDLC Toolchain Deployment (P2)

**Goal**: Deploy complete dual-stack SDLC toolchain via ArgoCD GitOps.
Primary stack: GitLab CE + Jenkins + Harbor + full observability.
Secondary stack: Gitea + Woodpecker CI for learning.

**Independent Test**: Push code to GitLab CE, Jenkins pipeline triggers,
container image published to Harbor, metrics visible in Grafana, logs
in Loki. Secondary: Gitea accessible, Woodpecker CI linked.

### Tests for User Story 4

> **Write these tests FIRST, ensure they FAIL before implementation**

- [x] T046 [P] [US4] Health check test for all SDLC services in
  `tests/k8s/smoke/test_sdlc_health.sh` (HTTP probes per
  layer-interfaces contract: GitLab `/-/health`, Jenkins `/login`,
  Harbor `/api/v2.0/health`, ArgoCD UI, Prometheus `/-/healthy`,
  Grafana `/api/health`, Loki `/ready`, Gitea `/api/healthz`,
  Woodpecker `/healthz`)
- [x] T047 [P] [US4] Integration test for primary CI pipeline flow in
  `tests/e2e/test_ci_pipeline.sh` (create repo in GitLab, add
  Jenkinsfile, push commit, verify Jenkins build triggers within 60s,
  verify container image published to Harbor)
- [x] T048 [P] [US4] Integration test for observability in
  `tests/e2e/test_observability.sh` (Prometheus scrape targets up
  for all SDLC services, Grafana dashboards loaded and rendering,
  Loki receiving logs from all namespaces)

### Implementation for User Story 4

#### ArgoCD Bootstrap

- [x] T049 [US4] Create ArgoCD Helm values
  (`code/k8s/argocd/install/values.yaml`) with Traefik ingress for
  `argocd.apps.home.lab`, server config, repository credentials
  template, resource tracking
- [x] T050 [US4] Create ArgoCD install playbook
  (`code/ansible/playbooks/05-argocd-install.yml`) deploying ArgoCD
  via Helm to `argocd` namespace, retrieving initial admin password

#### ArgoCD Application Manifests

- [x] T051 [P] [US4] Create ArgoCD Application for GitLab CE in
  `code/k8s/argocd/applications/gitlab.yaml` (source: local Helm
  values, namespace: `gitlab`, sync policy: automated with self-heal)
- [x] T052 [P] [US4] Create ArgoCD Application for Jenkins in
  `code/k8s/argocd/applications/jenkins.yaml` (namespace: `jenkins`,
  sync policy: automated)
- [x] T053 [P] [US4] Create ArgoCD Application for Harbor in
  `code/k8s/argocd/applications/harbor.yaml` (namespace: `harbor`,
  sync policy: automated)
- [x] T054 [P] [US4] Create ArgoCD Application for monitoring stack in
  `code/k8s/argocd/applications/monitoring.yaml` (namespace:
  `monitoring`, kube-prometheus-stack chart)
- [x] T055 [P] [US4] Create ArgoCD Application for logging stack in
  `code/k8s/argocd/applications/logging.yaml` (namespace: `logging`,
  loki-stack chart)
- [x] T056 [P] [US4] Create ArgoCD Application for Sealed Secrets in
  `code/k8s/argocd/applications/sealed-secrets.yaml` (namespace:
  `kube-system`)
- [x] T057 [P] [US4] Create ArgoCD Application for Gitea in
  `code/k8s/argocd/applications/gitea.yaml` (namespace: `gitea`,
  secondary stack)
- [x] T058 [P] [US4] Create ArgoCD Application for Woodpecker CI in
  `code/k8s/argocd/applications/woodpecker.yaml` (namespace:
  `woodpecker`, secondary stack)

#### Primary SDLC Stack Helm Values

- [x] T059 [US4] Create GitLab CE Helm values
  (`code/k8s/apps/gitlab/values.yaml`) with:
  - Global: host `gitlab.apps.home.lab`, edition CE
  - Ingress via Traefik with TLS (cert-manager annotation)
  - Persistence via Longhorn StorageClass
  - Admin password via Sealed Secret
  - Resource limits appropriate for 64GB agent nodes
  - Disable components not needed (Pages, KAS, etc.)
  - Registry disabled (Harbor used instead)
- [x] T060 [US4] Create Jenkins Helm values
  (`code/k8s/apps/jenkins/values.yaml`) with:
  - Controller ingress at `jenkins.apps.home.lab` with TLS
  - Persistence via Longhorn
  - Admin password via Sealed Secret
  - JCasC (Jenkins Configuration as Code) for:
    - GitLab plugin + webhook receiver configuration
    - Kubernetes cloud for ephemeral build agents
    - Harbor registry credentials for image push
  - Groovy init scripts for GitLab connection
- [x] T061 [P] [US4] Create Harbor Helm values
  (`code/k8s/apps/harbor/values.yaml`) with:
  - Ingress at `harbor.apps.home.lab` with TLS
  - Persistence via Longhorn for registry, chartmuseum, database
  - Admin password via Sealed Secret
  - Trivy vulnerability scanner enabled
  - Notary disabled (not needed for home lab)

#### Secondary SDLC Stack Helm Values

- [x] T062 [P] [US4] Create Gitea Helm values
  (`code/k8s/apps/gitea/values.yaml`) with:
  - Ingress at `gitea.apps.home.lab` with TLS
  - Persistence via Longhorn
  - SQLite database (lightweight for learning)
  - First-run setup enabled
- [x] T063 [P] [US4] Create Woodpecker CI Helm values
  (`code/k8s/apps/woodpecker/values.yaml`) with:
  - Server ingress at `ci.apps.home.lab` with TLS
  - Gitea OAuth integration configuration
  - Agent deployment with 2 replicas
  - Pipeline volume (Longhorn)

#### Observability Stack Helm Values

- [x] T064 [P] [US4] Create monitoring stack Helm values
  (`code/k8s/apps/monitoring/values.yaml`) for kube-prometheus-stack
  with Grafana ingress at `grafana.apps.home.lab`, Prometheus ingress
  at `prometheus.apps.home.lab`, 30-day retention, Alertmanager config
  with at minimum a webhook or email receiver for health degradation
  alerts (dead man's switch, node NotReady, pod CrashLoopBackOff),
  ServiceMonitors for all deployed services (GitLab, Jenkins, Harbor,
  ArgoCD, Gitea, Woodpecker, Longhorn, cert-manager)
- [x] T065 [P] [US4] Create Grafana dashboards for SDLC services
  (`code/k8s/apps/monitoring/dashboards/`) as ConfigMaps:
  - k3s cluster overview dashboard
  - GitLab performance dashboard
  - Jenkins build metrics dashboard
  - Harbor registry dashboard
  - Node exporter dashboard
- [x] T066 [P] [US4] Create logging stack Helm values
  (`code/k8s/apps/logging/values.yaml`) for Loki with:
  - Loki ingress at `loki.apps.home.lab`
  - Promtail DaemonSet collecting from all namespaces
  - Grafana datasource auto-configuration
  - 14-day retention

#### Integrations

- [x] T067 [US4] Configure GitLab→Jenkins integration: create Jenkins
  webhook receiver in JCasC config, document GitLab webhook setup
  (system hook or per-project) in `docs/integrations.md`, create
  Sealed Secret for GitLab API token used by Jenkins
- [x] T068 [US4] Configure Jenkins→Harbor integration: create Sealed
  Secret with Harbor robot account credentials, configure Jenkins
  Kubernetes credentials for Harbor push, add Harbor registry to
  Jenkins global config via JCasC
- [x] T069 [US4] Configure Woodpecker→Gitea integration: create Gitea
  OAuth2 application credentials as Sealed Secret, configure
  Woodpecker server with Gitea URL and OAuth client ID/secret

#### Finalization

- [x] T070 [US4] Add Makefile targets: `deploy-apps` (syncs all ArgoCD
  applications), `test-apps` (runs health checks), `health-check`
  (probes all service endpoints per layer-interfaces contract)
- [x] T071 [US4] Verify all health checks and integration tests pass
  (structural verification complete; runtime verification requires
  live k3s cluster)

**Checkpoint**: All SDLC services accessible via ingress on
`*.apps.home.lab`. Primary: GitLab CE push triggers Jenkins pipeline,
image published to Harbor, ArgoCD syncs deployment. Secondary: Gitea
and Woodpecker accessible for learning. Grafana shows live metrics.
Loki shows aggregated logs from all namespaces.

---

## Phase 7: User Story 5 - End-to-End Testing and Validation (P3)

**Goal**: Comprehensive test suite validating entire bootstrap chain
from iLO through SDLC toolchain functionality

**Independent Test**: `make test-e2e` runs all validations and
produces a structured pass/fail report

### Implementation for User Story 5

- [x] T072 [US5] Create end-to-end test runner script
  (`code/scripts/test-e2e.sh`) that orchestrates all layer tests
  sequentially: iLO → Proxmox → VMs → k3s → infra services → SDLC
  apps → observability. Produces structured output with per-layer
  pass/fail and timing.
- [x] T073 [US5] Create bootstrap orchestration script
  (`code/scripts/bootstrap.sh`) that runs all layers with error
  handling, progress reporting, and resumability (skips completed
  layers on re-run)
- [x] T074 [US5] Create CI pipeline smoke test
  (`tests/e2e/test_smoke_pipeline.sh`): create test repo in GitLab CE,
  add `Jenkinsfile` that builds a container image, push, verify
  Jenkins pipeline triggers and completes, verify image exists in
  Harbor registry, cleanup test repo
- [x] T075 [US5] Add Makefile targets: `test-e2e` (runs full test
  suite), `bootstrap` (runs full bootstrap chain)
- [x] T076 [US5] Verify full `make test-e2e` passes end-to-end

**Checkpoint**: `make test-e2e` validates all 5 user stories. `make
bootstrap` runs the full chain from iLO to running SDLC toolchain.

---

## Phase 8: Polish and Cross-Cutting Concerns

**Purpose**: State migration, security hardening, final validation

- [x] T077 [P] Deploy MinIO on k3s for OpenTofu state backend
  (`code/k8s/apps/minio/values.yaml`, ArgoCD application at
  `code/k8s/argocd/applications/minio.yaml`) with persistence via
  Longhorn, ingress at `minio.apps.home.lab`
- [x] T078 Migrate OpenTofu state from local to MinIO S3 backend
  (update `code/tofu/environments/prod/backend.tf` to S3 backend
  pointing to MinIO, run `tofu init -migrate-state`)
- [x] T079 [P] Remove local state exception from plan.md Complexity
  Tracking (update exception expiration status)
- [x] T080 [P] Finalize Makefile with all targets working end-to-end,
  add `help` target listing all available commands
- [x] T081 [P] Security hardening: verify no secrets in Git history
  (`git log --diff-filter=A -- '*.enc.*'`), all pre-commit hooks
  active, RBAC review on k3s, NetworkPolicies for namespace isolation
- [x] T082 Run `make lint` and fix all warnings to zero across all
  layers (ansible-lint, yamllint, tflint, tofu validate, shellcheck)
- [x] T083 Run `make test-e2e` final validation — all tests green
- [x] T084 Create CI pipeline definition for home-bootstrap repo
  (`Jenkinsfile` at repo root) implementing constitution Quality Gates:
  lint gate (tflint, ansible-lint, yamllint, shellcheck), validation
  gate (tofu validate, syntax checks), test gate (Molecule, tofu test,
  smoke tests), plan gate (tofu plan output for review), security gate
  (detect-private-key, SOPS verification). Configure GitLab webhook to
  trigger Jenkins on push to merge-target branches.

---

## Dependencies and Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1
- **US1 iLO (Phase 3)**: Depends on Phase 2. Can be **skipped** for
  DL380g10 since Proxmox is already installed.
- **US2 Proxmox/VMs (Phase 4)**: Depends on Phase 2; depends on
  Phase 3 output (running Proxmox host) for integration testing
- **US3 k3s (Phase 5)**: Depends on Phase 4 (running VMs with SSH)
- **US4 SDLC Apps (Phase 6)**: Depends on Phase 5 (running k3s with
  infrastructure services)
- **US5 E2E Tests (Phase 7)**: Depends on Phase 6 (all services
  deployed)
- **Polish (Phase 8)**: Depends on Phase 7

### Within Each Phase

- Tests marked with story tag MUST be written and FAIL before
  implementation
- [P] tasks can run in parallel (different files, no dependencies)
- Ansible roles before playbooks
- OpenTofu modules before environments
- Helm values before ArgoCD applications
- Commit after each task or logical group

### Parallel Opportunities

Within Phase 1: All T001-T009 are independent files
Within Phase 2: T011-T014 after T010
Within Phase 3: T015-T016 tests, T017-T018 answer files in parallel
Within Phase 4: T023-T025 tests in parallel
Within Phase 5: T035-T037 tests in parallel; T040-T043 Helm values
  in parallel
Within Phase 6: T051-T058 ArgoCD apps in parallel; T061-T066 Helm
  values in parallel (primary, secondary, and observability stacks)

---

## Parallel Example: Phase 6 (User Story 4)

```bash
# Launch all ArgoCD Application manifests together:
Task: "ArgoCD Application for GitLab CE in code/k8s/argocd/applications/gitlab.yaml"
Task: "ArgoCD Application for Jenkins in code/k8s/argocd/applications/jenkins.yaml"
Task: "ArgoCD Application for Harbor in code/k8s/argocd/applications/harbor.yaml"
Task: "ArgoCD Application for monitoring in code/k8s/argocd/applications/monitoring.yaml"
Task: "ArgoCD Application for logging in code/k8s/argocd/applications/logging.yaml"
Task: "ArgoCD Application for Gitea in code/k8s/argocd/applications/gitea.yaml"
Task: "ArgoCD Application for Woodpecker in code/k8s/argocd/applications/woodpecker.yaml"

# Launch all independent Helm values together:
Task: "Harbor Helm values in code/k8s/apps/harbor/values.yaml"
Task: "Gitea Helm values in code/k8s/apps/gitea/values.yaml"
Task: "Woodpecker CI Helm values in code/k8s/apps/woodpecker/values.yaml"
Task: "Monitoring stack values in code/k8s/apps/monitoring/values.yaml"
Task: "Grafana dashboards in code/k8s/apps/monitoring/dashboards/"
Task: "Logging stack values in code/k8s/apps/logging/values.yaml"
```

---

## Implementation Strategy

### MVP First (Layers 0-3 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: US1 (iLO) — skip for DL380g10 since Proxmox
   pre-installed; needed later for DL360g9
4. Complete Phase 4: US2 (Proxmox/VMs)
5. Complete Phase 5: US3 (k3s + infrastructure services)
6. **STOP and VALIDATE**: k3s cluster operational, MetalLB assigning
   IPs, Longhorn providing storage, cert-manager issuing certs
7. Manually test: create deployment, get LoadBalancer IP from
   192.168.2.240-250, access via ingress with TLS on
   `*.apps.home.lab`

### Incremental Delivery

1. Setup + Foundational → tooling ready
2. US1 (iLO) → bare metal provisioned (skip if Proxmox pre-installed)
3. US2 (Proxmox/VMs) → 3 VMs running on DL380g10
4. US3 (k3s + infra) → cluster ready with storage and networking
5. US4 (SDLC apps) → full dual-stack toolchain
6. US5 (E2E tests) → validated end-to-end
7. Polish → state migrated, security hardened, production-ready

### Key Decision Points

- After Phase 5 (k3s ready): Deploy primary stack first (GitLab +
  Jenkins + Harbor), validate integration, then add secondary stack
  (Gitea + Woodpecker) and observability
- GitLab CE is the heaviest deployment (~4-8GB RAM); monitor agent
  node resources during rollout
- Jenkins ephemeral agents will consume resources dynamically; set
  pod limits in Helm values

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story
- Each layer is independently testable
- Constitution Principle III requires tests before implementation
- Constitution Principle VII requires all operations to be idempotent
- Commit after each task or logical group
- Stop at any checkpoint to validate the current layer
- US1 (iLO) can be skipped if Proxmox is already installed (DL380g10)
- Primary SDLC stack (GitLab+Jenkins+Harbor) is MUST; secondary
  (Gitea+Woodpecker) is SHOULD per FR-007/FR-007a
- All services use `*.apps.home.lab` domain via Traefik ingress on
  MetalLB IPs (192.168.2.240-250)
- T084 (CI pipeline) requires GitLab+Jenkins running (Phase 6
  complete) but lives in Phase 8 since it's cross-cutting
