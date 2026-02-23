# Feature Specification: Bare Metal SDLC Bootstrap

**Feature Branch**: `001-bare-metal-sdlc-bootstrap`
**Created**: 2026-02-14
**Status**: Draft
**Input**: User description: "build an automated implementation chain of bare metal infrastructure from HPE ILOM with proxmox to fully implemented SDLC toolchain, focusing on code quality, testing, and idempotence of resource implementation"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - HPE iLO Server Provisioning (Priority: P1)

As an infrastructure operator, I run a single command that configures an
HPE server's iLO settings (BIOS, boot order, network) and initiates an
automated Proxmox VE installation via virtual media, so that bare metal
is transformed into a managed hypervisor without manual console
interaction.

**Why this priority**: Without a provisioned hypervisor, no subsequent
infrastructure layers can exist. This is the physical foundation.

**Independent Test**: Can be validated by running the provisioning
playbook against an iLO endpoint and verifying Proxmox VE is accessible
via API after completion.

**Acceptance Scenarios**:

1. **Given** a factory-default HPE server with iLO network access,
   **When** the operator runs `make provision-server HOST=<ilo-ip>`,
   **Then** iLO BIOS settings are configured, Proxmox VE ISO is mounted
   via virtual media, and the server boots into the Proxmox installer
   with an automated answer file.
2. **Given** a server already running Proxmox VE at the target version,
   **When** the operator re-runs `make provision-server HOST=<ilo-ip>`,
   **Then** the playbook reports "no changes" (idempotent).
3. **Given** an iLO endpoint that is unreachable,
   **When** the operator runs the provisioning command,
   **Then** the process fails with a clear error message within 30
   seconds and exits with a non-zero code.

---

### User Story 2 - Proxmox Infrastructure Layer (Priority: P1)

As an infrastructure operator, I apply OpenTofu configurations to a
Proxmox host to provision VMs with cloud-init, configure storage pools,
and set up networking, so that a compute platform is ready for
Kubernetes deployment.

**Why this priority**: Co-equal with US1 as part of the foundation.
VMs are the compute substrate for all SDLC services.

**Independent Test**: Can be validated by running `tofu apply` and
verifying VMs are reachable via SSH with correct cloud-init
configuration applied.

**Acceptance Scenarios**:

1. **Given** a running Proxmox VE host with API access,
   **When** the operator runs `tofu apply -target=module.proxmox_vms`,
   **Then** VMs are created with specified CPU, memory, disk, and
   network configuration, and cloud-init sets hostname, SSH keys, and
   static IP addresses.
2. **Given** VMs already exist matching the desired state,
   **When** `tofu apply` is re-run,
   **Then** the plan shows zero changes.
3. **Given** a VM spec change (e.g., increased memory),
   **When** `tofu apply` is run,
   **Then** only the changed resource is modified and the VM is
   available after the change.
4. **Given** the operator runs `tofu plan`,
   **Then** the output shows all proposed changes without applying them,
   and contains no secrets in plaintext.

---

### User Story 3 - Kubernetes Cluster Bootstrap (Priority: P2)

As an infrastructure operator, I run automated tooling that installs and
configures a k3s cluster across the provisioned VMs, including storage
(Longhorn), load balancing (MetalLB), ingress (Traefik), and
certificate management (cert-manager), so that the cluster is ready
to host SDLC workloads.

**Why this priority**: Kubernetes is the runtime platform for all
SDLC services but depends on US2 VMs being available first.

**Independent Test**: Can be validated by running `kubectl get nodes`
and verifying all nodes are Ready, and by deploying a test workload
with an ingress and verifying end-to-end connectivity.

**Acceptance Scenarios**:

1. **Given** provisioned VMs with network connectivity,
   **When** the operator runs `make bootstrap-k3s`,
   **Then** k3s server and agent nodes join the cluster, and
   `kubectl get nodes` shows all nodes in Ready state.
2. **Given** a running k3s cluster,
   **When** the bootstrap is re-run,
   **Then** the process is idempotent and reports no changes.
3. **Given** a k3s cluster with MetalLB configured,
   **When** a LoadBalancer Service is created,
   **Then** an IP from the configured pool is assigned within 30
   seconds.
4. **Given** a k3s cluster with cert-manager and a ClusterIssuer,
   **When** an Ingress with a TLS annotation is created,
   **Then** a valid TLS certificate is issued and the endpoint is
   accessible over HTTPS.

---

### User Story 4 - SDLC Toolchain Deployment (Priority: P2)

As a developer, I have access to a fully integrated SDLC toolchain
(source control, CI/CD, artifact registry, monitoring, logging) deployed
on the k3s cluster via GitOps, so that I can practice professional
software development workflows on my home infrastructure.

**Why this priority**: This is the user-facing value delivery but
depends on US3 cluster being operational.

**Independent Test**: Can be validated by pushing code to GitLab CE,
verifying a Jenkins pipeline triggers, an artifact is published to
Harbor, and metrics appear in Grafana.

**Acceptance Scenarios**:

1. **Given** a running k3s cluster with GitOps (ArgoCD),
   **When** the SDLC application manifests are synced,
   **Then** GitLab CE, Jenkins, Harbor, Prometheus, Grafana, Loki,
   and Alertmanager are deployed and accessible via ingress.
   Secondary stack (Gitea, Woodpecker CI) SHOULD also be deployed.
2. **Given** a deployed GitLab CE instance,
   **When** a developer pushes code to a repository with a
   `Jenkinsfile` pipeline,
   **Then** Jenkins triggers a build within 60 seconds.
3. **Given** a CI pipeline that builds a container image,
   **When** the build succeeds,
   **Then** the image is pushed to Harbor and is pullable by tag.
4. **Given** all SDLC services are running,
   **When** the operator checks Grafana,
   **Then** dashboards show metrics for all deployed services and
   Loki shows aggregated logs.

---

### User Story 5 - End-to-End Testing and Validation (Priority: P3)

As an infrastructure operator, I run an end-to-end test suite that
validates the entire bootstrap chain from iLO configuration through
SDLC toolchain functionality, so that I have confidence the system is
working correctly and can detect regressions.

**Why this priority**: Testing validates all prior stories but is not
blocking for initial deployment.

**Independent Test**: Can be validated by running `make test-e2e` and
checking all test assertions pass.

**Acceptance Scenarios**:

1. **Given** a fully bootstrapped environment,
   **When** `make test-e2e` is run,
   **Then** tests validate: iLO configuration matches desired state,
   Proxmox VMs are running, k3s nodes are Ready, all SDLC services
   respond to health checks, and a smoke-test CI pipeline completes.
2. **Given** a partially failed environment (e.g., GitLab pod down),
   **When** `make test-e2e` is run,
   **Then** the specific failure is identified in test output with
   actionable error messages.

---

### Edge Cases

- What happens when iLO firmware version is unsupported by the Redfish
  client? Bootstrap MUST detect version and fail with guidance.
- How does the system handle Proxmox API certificate validation when
  using self-signed certificates? MUST support configurable TLS
  verification.
- What happens when a k3s node fails to join the cluster? Ansible MUST
  retry with backoff and report the specific failure.
- How does the system handle disk space exhaustion on Proxmox storage?
  OpenTofu MUST pre-validate available storage before VM creation.
- What happens when a Helm chart version is unavailable? ArgoCD MUST
  report sync failure with the specific chart and version.
- How does the system handle network partition between k3s nodes?
  MetalLB and Longhorn MUST be configured with appropriate timeouts and
  the monitoring stack MUST alert on node NotReady.
- How is the Proxmox ISO served to iLO? The operator MUST stand up a
  temporary HTTP server (nginx/apache) on the local network serving
  the ISO at the URL configured in `proxmox_iso_url`. The playbook
  MUST validate the URL is reachable before attempting virtual media
  mount.

## Clarifications

### Session 2026-02-17

- Q: How many physical HPE servers and what models? → A: 2 servers — 1x DL360 Gen9 (iLO 4) + 1x DL380 Gen10 (iLO 5)
- Q: Server CPU/RAM/disk specs? → A: DL380g10: 2x Xeon Gold 6148 (40c), 768GB RAM, 8x 1.8TB. DL360g9: 2x Xeon E5-2690 v3 (24c), 128GB RAM, 8x 4TB + 4x 12TB
- Q: Network topology? → A: UniFi (UDMPRO gateway, USW-24-PoE, USW-Flex, US-8). 7 VLANs, each 192.168.VLAN_ID.0/24 with gateway at .1: VLAN 1 (default), VLAN 2 (lab-routed), VLAN 3 (lab-clustering), VLAN 4 (lab-storage), VLAN 5 (iLO), VLAN 201 (DMZ-A), VLAN 254 (guest). DHCP available on all. IGMP snooping on default/DMZ-A/lab-routed. mDNS proxy on all except lab-clustering. Fiber egress.
- Q: Server placement and roles? → A: DL380g10 is primary Proxmox host for k3s VMs. Both servers trunked to VLANs 2-5. iLO management on VLAN 5 (192.168.5.0/24).
- Q: Is Proxmox already installed? → A: DL380g10 has Proxmox VE already. DL360g9 does not (needs provisioning or different role). US1 iLO provisioning primarily needed for DL360g9 (iLO 4).
- Q: Disk/storage configuration? → A: DL380g10 uses hardware RAID controller (current Proxmox host). DL360g9 storage role TBD (80+ TB raw capacity available).
- Q: DNS setup? → A: NextDNS for external resolution. UniFi internal DNS today. Local DNS via CoreDNS on k3s (MetalLB IP), serving `*.lab.demena.net` wildcard, distributable via DHCP to lab subnets.
- Q: Existing VMs/services? → A: DL380 has VMs that can be flushed for a clean start. Pre-requisite: export Kimai time tracking data before teardown. Otherwise clean slate.
- Q: Who uses the SDLC toolchain? → A: Primarily solo operator/developer. Also used as a learning and demo platform for others occasionally. No multi-tenancy or SSO required initially.
- Q: DL360g9 role? → A: Standalone NAS (TrueNAS or similar), not part of bootstrap automation. Provisioned and managed separately.
- Q: Backup strategy for persistent SDLC data? → A: Longhorn S3 backups to DL360g9 NAS (off-node, higher durability). S3 endpoint on NAS via MinIO gateway or TrueNAS S3 service.
- Q: How is the Proxmox ISO served for iLO virtual media? → A: Temporary IP-based web server (nginx/apache) on the local network. Operator stands up a lightweight HTTP server serving the ISO before running iLO provisioning. Not a permanent service.
- Q: Single k3s server or HA? → A: 3-server HA with embedded etcd (k3s-server-01/02/03) plus 2 agent workers. k3s runs as VMs on Proxmox. Goal is practice and exposure to proper manager/worker node separation.
- Q: Local DNS and ingress domain? → A: CoreDNS on k3s via MetalLB serving wildcard `*.${INGRESS_DOMAIN}` → Traefik LB IP, DHCP-distributable to lab VLANs. Domain is configurable via `.env` file (gitignored); default `lab.demena.net`. A `.env.example` documents all required variables so others can fork and customize. Code MUST NOT hardcode the domain — all references use variables sourced from `.env`.
- Q: SDLC tool preferences and MVP scope? → A: **DECIDED** — Dual-stack approach:
  - **Primary SDLC**: GitLab CE (MIT) + Jenkins (MIT) + Harbor (Apache 2.0) + ArgoCD (Apache 2.0) + full observability
  - **Secondary/learning**: Gitea (MIT) + Woodpecker CI (Apache 2.0) deployed alongside for exposure to lightweight cloud-native alternatives
  - Goal: portable, replicable deployment toolchains with enterprise familiarity
  - Harbor retained as dedicated registry (vulnerability scanning, replication capabilities beyond GitLab's built-in registry)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST automate HPE iLO configuration (BIOS settings,
  boot order, network) via Redfish API using Ansible
- **FR-002**: System MUST automate Proxmox VE installation via iLO
  virtual media with an unattended answer file
- **FR-003**: System MUST provision Proxmox VMs using OpenTofu with the
  bpg/proxmox provider, with cloud-init for OS-level configuration
- **FR-004**: System MUST configure Proxmox storage pools (ZFS or LVM)
  and networking (bridges, VLANs) via OpenTofu or Ansible
- **FR-005**: System MUST deploy k3s in an HA multi-node configuration
  (3 server nodes with embedded etcd + 2 agent workers) using Ansible
- **FR-006**: System MUST deploy cluster infrastructure services:
  MetalLB (load balancing), Longhorn (storage), Traefik (ingress),
  cert-manager (TLS)
- **FR-007**: System MUST deploy primary SDLC toolchain via ArgoCD
  GitOps: GitLab CE (source control, project management), Jenkins
  (CI/CD pipelines), Harbor (container registry)
- **FR-007a**: System SHOULD deploy secondary SDLC toolchain via ArgoCD
  GitOps: Gitea (lightweight source control), Woodpecker CI (lightweight
  CI/CD) — for learning and comparison alongside primary stack
- **FR-008**: System MUST deploy observability stack via ArgoCD:
  Prometheus + Grafana (metrics), Loki (logging), Alertmanager (alerts)
- **FR-009**: All IaC modules MUST pass `tofu validate` and linting
  before apply (Constitution Principle III)
- **FR-010**: All Ansible playbooks MUST pass `ansible-lint` and
  `yamllint` (Constitution Principle III)
- **FR-011**: All operations MUST be idempotent — re-running any
  automation step MUST converge to desired state without side effects
  (Constitution Principle VII)
- **FR-012**: Secrets MUST be managed via SOPS+age or Sealed Secrets,
  never committed in plaintext (Constitution Principle I)
- **FR-013**: System MUST expose a Makefile or task runner as the
  single entry point for all operations
- **FR-014**: All tool selections MUST document license type in a
  component inventory (Constitution Principle II)
- **FR-015**: System MUST include integration tests validating
  cross-layer connectivity (iLO → Proxmox → k3s → services)
- **FR-016**: Longhorn MUST be configured with scheduled S3 backups
  targeting the DL360g9 NAS (off-node) for persistent volume data
  (GitLab repos, Harbor images, Jenkins configs, Prometheus metrics)
- **FR-017**: System MUST deploy CoreDNS on k3s exposed via MetalLB
  serving wildcard `*.lab.demena.net` resolving to the Traefik
  LoadBalancer IP, distributable to lab VLANs via DHCP
- **FR-018**: All service ingress hostnames MUST use the
  `*.lab.demena.net` domain (e.g., `gitlab.lab.demena.net`,
  `jenkins.lab.demena.net`)

### Key Entities

- **Server**: Physical HPE server with iLO endpoint; 2 servers:
  DL380 Gen10 (iLO 5, 40c/768GB/8x1.8TB, primary — runs all k3s VMs)
  and DL360 Gen9 (iLO 4, 24c/128GB/80+TB, standalone NAS — outside
  bootstrap scope, managed separately as TrueNAS or similar).
  Attributes: iLO IP, model, iLO generation, firmware version,
  desired BIOS settings. NOTE: iLO 4 (DL360g9) provisioning via
  this bootstrap is optional; iLO playbook retained for reference
  but DL360g9 is not part of the automated bootstrap chain
- **Hypervisor**: Proxmox VE instance running on a Server; attributes:
  hostname, management IP, API credentials, storage pools, networks
- **VM**: Virtual machine on a Hypervisor; attributes: vmid, hostname,
  CPU, memory, disk, network, cloud-init config, role (k3s-server,
  k3s-agent, utility)
- **Cluster**: k3s Kubernetes cluster in HA configuration (3 server
  nodes with embedded etcd, 2 agent workers); attributes: server
  endpoint (load-balanced or first server), join token, node list,
  installed add-ons, ingress domain `*.lab.demena.net`
- **Service**: SDLC application deployed on Cluster; attributes: name,
  Helm chart, namespace, ingress hostname, health endpoint

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A bare metal server can be fully bootstrapped from iLO to
  operational SDLC toolchain with a single `make bootstrap` invocation
  (excluding hardware racking and iLO network setup)
- **SC-002**: Re-running the full bootstrap on an already-provisioned
  environment produces zero changes across all layers
- **SC-003**: All IaC modules pass `tofu validate` and `tofu plan`
  shows expected changes only
- **SC-004**: All Ansible playbooks pass linting with zero warnings
- **SC-005**: End-to-end test suite validates all 5 user stories with
  a pass/fail report
- **SC-006**: A code push to the self-hosted GitLab CE triggers a
  Jenkins pipeline that builds and publishes a container image to
  Harbor within 5 minutes
- **SC-007**: Grafana dashboards show live metrics for all deployed
  services; Loki shows logs from all namespaces
- **SC-008**: Every tool in the stack is documented in a component
  inventory with name, version, license, and purpose
