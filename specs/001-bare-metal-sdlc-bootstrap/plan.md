# Implementation Plan: Bare Metal SDLC Bootstrap

**Branch**: `001-bare-metal-sdlc-bootstrap` | **Date**: 2026-02-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-bare-metal-sdlc-bootstrap/spec.md`

## Summary

Build an automated, idempotent implementation chain that provisions bare
metal HPE servers (DL360 Gen9 + DL380 Gen10) from iLO through Proxmox
hypervisor to a fully operational SDLC toolchain running on k3s. The
primary SDLC stack is GitLab CE + Jenkins + Harbor + ArgoCD with full
observability (Prometheus, Grafana, Loki). A secondary lightweight stack
(Gitea + Woodpecker CI) is deployed alongside for learning. The
bootstrap uses Ansible for imperative provisioning (iLO, Proxmox host
config, k3s install), OpenTofu for declarative resource management (VMs,
network), and ArgoCD GitOps for Kubernetes workload deployment. Every
layer is code-defined, tested, and re-runnable without side effects.

## Technical Context

**Language/Version**: HCL (OpenTofu >= 1.7), YAML (Ansible >= 2.16),
Bash (shell glue/Makefile), Groovy (Jenkinsfile pipelines)
**Primary Dependencies**: OpenTofu, Ansible, k3s, Helm, ArgoCD,
bpg/proxmox provider, community.general collection, DMTF redfish
Python library, proxmoxer Python library
**Storage**: Hardware RAID on DL380g10 (Proxmox host), Longhorn on k3s
(distributed block storage), MinIO on k3s (S3-compatible for state
backend). DL360g9 storage role TBD (80+ TB raw).
**Testing**: ansible-lint, yamllint, tofu validate, tflint, tofu test,
Molecule, shellcheck, pre-commit hooks, custom integration test suite
**Target Platform**: HPE DL380 Gen10 (primary Proxmox host, iLO 5) +
HPE DL360 Gen9 (secondary, iLO 4). k3s on Ubuntu 24.04 LTS VMs.
UniFi-managed VLAN network (UDMPRO + managed switches).
**Project Type**: Infrastructure-as-Code (multi-layer, single repo)
**Performance Goals**: Full bootstrap completes in <2 hours; individual
layer re-runs <15 minutes; SDLC services available within 10 minutes of
k3s cluster ready
**Constraints**: DL380g10 primary host (768GB RAM, 40c, 8x1.8TB).
DL360g9 iLO 4 may require Advanced license for virtual media. Home
network with VLANs (no BGP). Self-signed TLS acceptable initially.
**Scale/Scope**: 2 physical servers, 3-6 VMs on DL380, 15+ Kubernetes
workloads, single operator with occasional demo use

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Everything as Code (NON-NEGOTIABLE) | PASS | All layers defined as Ansible playbooks, OpenTofu modules, Helm charts, and ArgoCD Application manifests in version control |
| II. Open Source First, Permissive Licensed | PASS | All primary tools documented with licenses. Copyleft exceptions documented: Ansible (GPL-3.0), Grafana (AGPL-3.0), Loki (AGPL-3.0). All primary SDLC tools permissive: GitLab CE (MIT), Jenkins (MIT), Harbor (Apache 2.0), ArgoCD (Apache 2.0) |
| III. Test-Driven Infrastructure (NON-NEGOTIABLE) | PASS | ansible-lint + yamllint for playbooks, tofu validate + tflint for modules, Molecule for roles, pre-commit hooks, CI pipeline, integration test suite |
| IV. Systems Engineering Discipline | PASS | Requirements traced to user stories (spec.md), interfaces documented (contracts/), modular decomposition (layer-per-directory), semantic versioning |
| V. Comprehensive SDLC Platform | PASS | All 8 lifecycle phases covered: Plan (GitLab issues), Code (GitLab), Build (Jenkins), Test (Jenkins), Release (Harbor), Deploy (ArgoCD), Operate (k3s), Monitor (Prometheus/Grafana/Loki) |
| VI. DevOps Toolchain Integration | PASS | GitLab webhooks trigger Jenkins, artifacts to Harbor, monitoring pre-configured, log aggregation via Loki, all integrations code-defined |
| VII. Reproducibility and Idempotency | PASS | tofu apply idempotent, Ansible playbooks use check-before-apply, container images pinned, cloud-init scripted, documented state recovery path |

**Exceptions Required**:

| Principle | Exception | Expiration | Exit Strategy |
|-----------|-----------|------------|---------------|
| I / VII | Local OpenTofu state during initial bootstrap (before MinIO available) | 30 days post-bootstrap | RESOLVED: MinIO deployed on k3s, S3 backend configured in code/tofu/environments/prod/backend.tf. Run `tofu init -migrate-state` to complete. |
| II | iLO Advanced license may be required for DL360g9 (proprietary HPE) | N/A (hardware constraint) | Document as hardware prerequisite; iLO 5 (DL380g10) uses free Standard license |

## Project Structure

### Documentation (this feature)

```text
specs/001-bare-metal-sdlc-bootstrap/
├── plan.md              # This file
├── research.md          # Phase 0: Technology decisions
├── data-model.md        # Phase 1: Entity and state model
├── quickstart.md        # Phase 1: Getting started guide
├── contracts/           # Phase 1: Interface contracts
│   ├── inventory-schema.md
│   └── layer-interfaces.md
└── tasks.md             # Phase 2: Implementation tasks
```

### Source Code (repository root)

```text
code/
├── ansible/
│   ├── inventory/
│   │   ├── group_vars/
│   │   │   ├── all.yml
│   │   │   ├── proxmox.yml
│   │   │   ├── k3s_server.yml
│   │   │   ├── k3s_agent.yml
│   │   │   ├── k3s_cluster.yml
│   │   │   └── secrets.enc.yml          # SOPS-encrypted
│   │   └── hosts.yml
│   ├── playbooks/
│   │   ├── 00-ilo-provision.yml
│   │   ├── 01-proxmox-configure.yml
│   │   ├── 02-cloud-image-template.yml
│   │   ├── 03-k3s-install.yml
│   │   ├── 04-k3s-post-install.yml
│   │   └── 05-argocd-install.yml
│   ├── roles/
│   │   ├── ilo_provision/
│   │   ├── proxmox_configure/
│   │   └── cloud_image_template/
│   ├── files/
│   │   ├── proxmox-answer-dl380.toml
│   │   └── proxmox-answer-dl360.toml
│   ├── ansible.cfg
│   └── requirements.yml
├── tofu/
│   ├── modules/
│   │   └── proxmox-vm/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── tests/
│   │           └── basic.tftest.hcl
│   ├── environments/
│   │   └── prod/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── terraform.tfvars
│   │       └── backend.tf
│   └── .tflint.hcl
├── k8s/
│   ├── argocd/
│   │   ├── install/
│   │   │   └── values.yaml
│   │   └── applications/
│   │       ├── gitlab.yaml              # Primary: source control
│   │       ├── jenkins.yaml             # Primary: CI/CD
│   │       ├── harbor.yaml              # Primary: registry
│   │       ├── minio.yaml              # State backend (S3)
│   │       ├── gitea.yaml               # Secondary: lightweight SCM
│   │       ├── woodpecker.yaml          # Secondary: lightweight CI
│   │       ├── monitoring.yaml
│   │       └── logging.yaml
│   ├── infrastructure/
│   │   ├── metallb/
│   │   │   ├── values.yaml
│   │   │   └── ip-pool.yaml
│   │   ├── longhorn/
│   │   │   └── values.yaml
│   │   ├── cert-manager/
│   │   │   ├── values.yaml
│   │   │   └── cluster-issuer.yaml
│   │   └── sealed-secrets/
│   │       └── values.yaml
│   └── apps/
│       ├── gitlab/                      # Primary
│       │   └── values.yaml
│       ├── jenkins/                     # Primary
│       │   ├── values.yaml
│       │   └── sealed-secrets/          # SealedSecret templates
│       ├── harbor/                      # Primary
│       │   └── values.yaml
│       ├── minio/                       # State backend
│       │   └── values.yaml
│       ├── gitea/                       # Secondary
│       │   └── values.yaml
│       ├── woodpecker/                  # Secondary
│       │   ├── values.yaml
│       │   └── sealed-secrets/          # SealedSecret templates
│       ├── monitoring/
│       │   ├── values.yaml
│       │   └── dashboards/              # Grafana dashboard ConfigMaps
│       └── logging/
│           └── values.yaml
├── scripts/
│   ├── bootstrap.sh
│   └── test-e2e.sh
└── Makefile

tests/
├── ansible/
│   ├── lint/                            # Playbook lint assertions
│   └── molecule/                        # Role molecule tests
├── tofu/
│   └── integration/
├── k8s/
│   └── smoke/                           # Cluster, infra, SDLC health
└── e2e/
    ├── test_ilo_provision.sh
    ├── test_vm_provision.sh
    ├── test_ci_pipeline.sh
    ├── test_smoke_pipeline.sh
    └── test_observability.sh
```

**Structure Decision**: Multi-layer infrastructure project with clear
separation by tooling domain (ansible/, tofu/, k8s/). Each layer maps
to a user story and can be developed/tested independently. A top-level
Makefile provides the single entry point per FR-013. Primary and
secondary SDLC stacks share the same ArgoCD GitOps pattern but are
deployed as independent ArgoCD Applications.

## Hardware Inventory

| Server | Model | iLO | CPUs | RAM | Disks | Proxmox | Role |
|--------|-------|-----|------|-----|-------|---------|------|
| DL380g10 | DL380 Gen10 | iLO 5 | 2x Xeon Gold 6148 (40c) | 768GB | 8x 1.8TB (HW RAID) | Installed | Primary: k3s VMs |
| DL360g9 | DL360 Gen9 | iLO 4 | 2x Xeon E5-2690 v3 (24c) | 128GB | 8x 4TB + 4x 12TB | Not installed | TBD: storage/2nd node |

## Network Topology

**Gateway**: UniFi Dream Machine Pro (UDMPRO) with fiber egress
**Switches**: USW-24-PoE, USW-Flex, US-8
**DNS**: NextDNS (external), UniFi (internal); local DNS service desired

| VLAN | Subnet | Purpose | Servers |
|------|--------|---------|---------|
| 1 | 192.168.1.0/24 | Default / client devices | — |
| 2 | 192.168.2.0/24 | Lab-routed (VM traffic, services) | DL380, DL360 |
| 3 | 192.168.3.0/24 | Lab-clustering (k3s inter-node) | DL380, DL360 |
| 4 | 192.168.4.0/24 | Lab-storage (NFS, Ceph, bulk I/O) | DL380, DL360 |
| 5 | 192.168.5.0/24 | iLO out-of-band management | DL380 iLO, DL360 iLO |
| 201 | 192.168.201.0/24 | DMZ-A (externally reachable) | — |
| 254 | 192.168.254.0/24 | Guest network | — |

## VM Sizing (DL380g10 — primary host)

Given 768GB RAM / 40 cores available, VM sizes are generous to avoid
resource contention with GitLab and observability stack:

| VM | VMID | Role | CPU | RAM | Disk | VLAN 2 IP |
|----|------|------|-----|-----|------|-----------|
| k3s-server-01 | 100 | k3s control plane | 8 | 16GB | 100GB | 192.168.2.100 |
| k3s-agent-01 | 200 | k3s worker (primary workloads) | 8 | 64GB | 200GB | 192.168.2.200 |
| k3s-agent-02 | 201 | k3s worker (observability + secondary) | 8 | 64GB | 200GB | 192.168.2.201 |

**Total allocated**: 24 cores / 144GB RAM / 500GB disk
**Remaining on host**: 16 cores / 624GB RAM for future VMs

## SDLC Toolchain Architecture

### Primary Stack (MUST)

| Role | Tool | License | Helm Chart | Namespace |
|------|------|---------|------------|-----------|
| Source Control + PM | GitLab CE | MIT | `gitlab/gitlab` | `gitlab` |
| CI/CD Pipelines | Jenkins | MIT | `jenkins/jenkins` | `jenkins` |
| Container Registry | Harbor | Apache 2.0 | `harbor/harbor` | `harbor` |
| GitOps | ArgoCD | Apache 2.0 | `argo/argo-cd` | `argocd` |
| Metrics | Prometheus | Apache 2.0 | `prometheus-community/kube-prometheus-stack` | `monitoring` |
| Dashboards | Grafana | AGPL-3.0* | (bundled in kube-prometheus-stack) | `monitoring` |
| Logging | Loki | AGPL-3.0* | `grafana/loki-stack` | `logging` |
| Alerting | Alertmanager | Apache 2.0 | (bundled in kube-prometheus-stack) | `monitoring` |

### Secondary Stack (SHOULD — learning/comparison)

| Role | Tool | License | Helm Chart | Namespace |
|------|------|---------|------------|-----------|
| Source Control | Gitea | MIT | `gitea-charts/gitea` | `gitea` |
| CI/CD | Woodpecker CI | Apache 2.0 | `woodpecker/woodpecker` | `woodpecker` |

\* AGPL-3.0 accepted per constitution Principle II exception for
dominant solution with no permissive alternative at comparable maturity.

### Integration Flow

```
Developer pushes code → GitLab CE
  → GitLab webhook triggers Jenkins pipeline
    → Jenkins builds container image
      → Jenkins pushes image to Harbor
        → ArgoCD detects new image tag (image updater or webhook)
          → ArgoCD syncs deployment to k3s
            → Prometheus scrapes metrics
            → Loki collects logs
            → Grafana displays dashboards
```

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Multiple IaC tools (Ansible + OpenTofu + Helm) | Each tool excels at its layer: Ansible for imperative provisioning, OpenTofu for declarative state, Helm for K8s packaging | Single-tool approach cannot cover bare metal → Kubernetes span effectively |
| Local state bootstrap exception | MinIO (state backend) runs on k3s which is provisioned by OpenTofu | Circular dependency; no simpler resolution without external service |
| Dual SDLC stack (GitLab+Jenkins + Gitea+Woodpecker) | Learning/comparison goal; secondary stack is lightweight (<1GB combined) | Single stack would miss learning opportunity; secondary adds minimal overhead |
| iLO 4 vs iLO 5 handling | DL360g9 uses iLO 4 with different Redfish capabilities | Cannot change hardware; playbook must branch on iLO version |
| GitLab CE on k3s (heavy) | User preference for enterprise-familiar tools; 768GB RAM makes resource concerns irrelevant | GitLab as VM would remove it from GitOps; keeping on k3s maintains Principle I consistency |
