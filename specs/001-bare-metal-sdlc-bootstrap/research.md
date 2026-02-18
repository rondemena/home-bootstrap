# Research: Bare Metal SDLC Bootstrap

**Date**: 2026-02-17 (revised from 2026-02-14)
**Branch**: `001-bare-metal-sdlc-bootstrap`

## Layer 0: HPE iLO Automation

### Decision: Use DMTF Redfish via Ansible `community.general.redfish_*` modules

**Rationale**: Vendor-neutral, well-maintained, works with HPE iLO 4+/5/6.
The `redfish` Python library is BSD 3-Clause (Principle II compliant).
Ansible modules provide idempotent check-before-apply patterns natively.

**Alternatives considered**:
- `python-ilorest-library` (HPE official, Apache 2.0): Viable but
  HPE-specific. Redfish modules are vendor-neutral and sufficient.
- `python-hpilo` (community): Uses legacy RIBCL protocol. Limited
  iLO 5+ support. Rejected.
- `ilorest` CLI (HPE): Proprietary license. Rejected per Principle II.
- `sushy` (OpenStack/Ironic): Apache 2.0, production-grade but adds
  OpenStack dependency weight for a simpler use case.

### Key Ansible Modules

| Module | Purpose |
|--------|---------|
| `community.general.redfish_info` | Read power state, BIOS settings, virtual media state |
| `community.general.redfish_command` | Power on/off/restart, set boot device, mount/eject virtual media |
| `community.general.redfish_config` | Configure BIOS attributes (VT-x, VT-d, boot mode) |

### iLO License Requirements

**Actual hardware**: DL380 Gen10 (iLO 5) + DL360 Gen9 (iLO 4)

- **iLO Standard (free)**: Sufficient for iLO 5+ (Gen10/Gen10+, Gen11).
  Covers: Redfish API, power control, BIOS config, boot order, URL-based
  virtual media mounting. **DL380g10 uses this.**
- **iLO Advanced (paid)**: Required for iLO 4 (Gen8/Gen9) scripted
  virtual media operations, persistent virtual media mounting, and
  graphical remote console. **DL360g9 may require this** for automated
  ISO mount via Redfish. If Advanced license is not available, DL360g9
  Proxmox installation falls back to manual ISO boot.

### iLO 4 vs iLO 5 Differences

| Capability | iLO 4 (DL360g9) | iLO 5 (DL380g10) |
|------------|------------------|-------------------|
| Redfish API | Supported (v1 base) | Full support (v1.6+) |
| URL-based virtual media | Advanced license only | Standard (free) |
| BIOS config via Redfish | Supported | Supported |
| One-time boot | Supported | Supported |
| Boot order management | Limited Redfish; use RIBCL fallback | Full Redfish |
| Power control | Supported | Supported |

**Implementation impact**: The `ilo_provision` Ansible role MUST detect
iLO version and branch behavior accordingly. For iLO 4 without Advanced
license, virtual media mounting is skipped and operator is instructed to
manually boot the Proxmox ISO.

### Virtual Media Workflow

1. Serve Proxmox ISO via HTTP (nginx/caddy on local fileserver or
   workstation)
2. Mount ISO via `VirtualMediaInsert` Redfish command
3. Set one-time boot to CD via `SetOneTimeBoot`
4. Power cycle server via `PowerForceRestart`
5. Wait for Proxmox auto-installer to complete (SSH probe)
6. Eject virtual media via `VirtualMediaEject`

### Idempotent Pattern

Read current state with `redfish_info` before applying changes with
`redfish_config`. Only reboot if BIOS changes were applied. Guard
virtual media operations by checking current mount state.

---

## Layer 1: Proxmox VE Provisioning

### Decision: Proxmox auto-installer (answer.toml) + lae.proxmox Ansible role

**Rationale**: PVE 8.1+ supports native unattended installation via
TOML answer files. The `lae.proxmox` Ansible role (MIT) handles
post-install cluster configuration, storage, and user management.

**Alternatives considered**:
- Debian preseed + PVE packages: More complex, two-stage install.
  Rejected for initial implementation; viable fallback.
- PXE boot with auto-installer: Better for multi-node at scale.
  Deferred to future iteration.

### Current State

- **DL380g10**: Proxmox VE already installed. Hardware RAID controller
  in use. This server is ready for VM provisioning immediately — Layer 0
  (iLO provisioning) can be skipped for this host.
- **DL360g9**: No OS installed. Requires provisioning via iLO 4. Role
  TBD (could be second Proxmox node or dedicated storage server).

### Proxmox Answer File Format (answer.toml)

Example for DL360g9 (when provisioned):

```toml
[global]
keyboard = "en-us"
country = "us"
fqdn = "pve-02.home.lab"
mailto = "admin@home.lab"
timezone = "America/New_York"
root_password = "changeme"

[network]
source = "from-answer"
cidr = "192.168.2.12/24"
dns = "192.168.1.1"
gateway = "192.168.2.1"

[disk-setup]
filesystem = "zfs"
zfs.raid = "mirror"
zfs.compress = "on"
zfs.ashift = 12
```

---

## Layer 2: VM Provisioning on Proxmox

### Decision: OpenTofu with bpg/proxmox provider (MPL-2.0)

**Rationale**: Most actively maintained Proxmox provider. MPL-2.0
license aligns with Principle II. Broad resource coverage including
VMs, containers, network, firewall, RBAC, HA. Native cloud-init
support via `initialization {}` block.

**Alternatives considered**:
- `Telmate/proxmox` provider (MIT): Maintenance has stalled as of
  2024-2025. Narrower resource coverage. Rejected despite MIT license
  due to quality/maintenance concerns.
- Ansible `community.general.proxmox_kvm`: GPL-3.0 (accepted per
  constitution). Works but not declarative state management. Better
  suited as complement to OpenTofu, not replacement.

### Key OpenTofu Resources (bpg/proxmox)

| Resource | Purpose |
|----------|---------|
| `proxmox_virtual_environment_vm` | QEMU VM lifecycle |
| `proxmox_virtual_environment_file` | Upload ISOs, snippets, cloud-init |
| `proxmox_virtual_environment_network_linux_bridge` | Network bridges |
| `proxmox_virtual_environment_firewall_rules` | Firewall rules |
| `proxmox_virtual_environment_role` | RBAC roles |
| `proxmox_virtual_environment_user` | User management |

### Cloud-Init Integration

Template preparation (one-time, Ansible-scripted):
1. Download cloud image (Ubuntu 24.04 LTS cloud-img)
2. Create VM shell with `qm create`
3. Import disk with `qm importdisk`
4. Add cloud-init drive (`--ide2 local:cloudinit`)
5. Convert to template (`qm template`)

VMs cloned from template receive cloud-init config via OpenTofu's
`initialization {}` block (IP, SSH keys, hostname, custom user-data).

### VM Sizing Rationale

With 768GB RAM and 40 cores on the DL380g10, VM sizes are generous:

| VM | VMID | CPU | RAM | Disk | Rationale |
|----|------|-----|-----|------|-----------|
| k3s-server-01 | 100 | 8c | 16GB | 100GB | Control plane; etcd is memory-hungry under load |
| k3s-agent-01 | 200 | 8c | 64GB | 200GB | GitLab CE alone recommends 8GB+; Jenkins master + Harbor add more |
| k3s-agent-02 | 201 | 8c | 64GB | 200GB | Observability stack (Prometheus retention, Loki) + secondary SDLC stack |

Total: 24c / 144GB / 500GB — leaves 16c / 624GB / majority of RAID array for growth.

### Network Configuration

VMs use VLAN-tagged interfaces on Proxmox:

| Interface | VLAN | Purpose |
|-----------|------|---------|
| vmbr0.2 | 2 | Lab-routed: primary VM traffic, service access |
| vmbr0.3 | 3 | Lab-clustering: k3s inter-node, Longhorn replication |
| vmbr0.4 | 4 | Lab-storage: NFS, bulk data (future) |

Each VM gets a primary NIC on VLAN 2 (lab-routed) for service traffic.
k3s flannel/calico uses the VLAN 2 interface. Longhorn replication
optionally uses VLAN 3 for isolation.

### State Backend Strategy

**Chicken-and-egg problem**: OpenTofu needs a remote state backend
(per constitution), but the backend runs on infrastructure that
OpenTofu provisions.

**Resolution**: Two-phase approach:
1. **Phase A (bootstrap)**: Use local state file (exception documented
   per constitution governance). Provision Proxmox VMs and k3s cluster.
2. **Phase B (migration)**: Deploy MinIO on k3s as S3-compatible
   backend. Migrate OpenTofu state with `tofu init -migrate-state`.
   Delete local state file.

Exception document: Principle I/VII temporary deviation, 30-day
expiration, exit strategy is MinIO deployment.

---

## Layer 3: Kubernetes (k3s) Deployment

### Decision: k3s via PyratLabs/ansible-role-k3s (MIT)

**Rationale**: MIT-licensed Ansible role with Molecule tests. Supports
single-server, multi-agent, and HA topologies. Handles k3s installation,
configuration, and service management idempotently.

**Alternatives considered**:
- `k3sup` (MIT): CLI tool, good for quick setup. Not Ansible-native,
  harder to integrate into the playbook-based pipeline. Useful for
  manual bootstrapping/debugging.
- `xanmanning.k3s` (MIT): Similar role, less actively maintained.
  Rejected.
- Manual `curl | sh` install: Not idempotent, not testable. Rejected.

### Cluster Topology

1 server + 2 agents (3 VMs) on DL380g10:

| Role | VM | Resources | Purpose |
|------|----|-----------|---------|
| k3s server | k3s-server-01 (VMID 100) | 8c, 16GB, 100GB | Control plane + etcd |
| k3s agent | k3s-agent-01 (VMID 200) | 8c, 64GB, 200GB | Primary SDLC workloads |
| k3s agent | k3s-agent-02 (VMID 201) | 8c, 64GB, 200GB | Observability + secondary stack |

Future HA: Add 2 more server nodes (VMIDs 101, 102) with embedded etcd.

### Cluster Infrastructure Services

| Component | Tool | License | Helm Chart |
|-----------|------|---------|------------|
| Load Balancer | MetalLB | Apache 2.0 | `metallb/metallb` |
| Storage | Longhorn | Apache 2.0 | `longhorn/longhorn` |
| Ingress | Traefik | MIT | Bundled with k3s |
| TLS/Certs | cert-manager | Apache 2.0 | `jetstack/cert-manager` |
| DNS | CoreDNS | Apache 2.0 | Bundled with k3s |
| GitOps | ArgoCD | Apache 2.0 | `argo/argo-cd` |

### MetalLB Configuration

Layer 2 mode on VLAN 2 (lab-routed):

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
spec:
  addresses:
    - 192.168.2.240-192.168.2.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
```

---

## Layer 4: SDLC Toolchain

### Decision: Dual-stack — GitLab CE + Jenkins (primary) + Gitea + Woodpecker (secondary), all via ArgoCD GitOps

**Rationale**: Primary stack uses enterprise-familiar tools the operator
already knows (GitLab, Jenkins). Secondary stack deploys lightweight
cloud-native alternatives (Gitea, Woodpecker) for learning and
comparison. All deployed via ArgoCD for consistent GitOps management.
Harbor serves as the dedicated container registry for both stacks
(vulnerability scanning, replication).

**Alternatives considered**:
- GitLab-only (using GitLab CI instead of Jenkins): Maximum
  consolidation but loses Jenkins plugin ecosystem and learning
  opportunity.
- Gitea + Woodpecker only (original spec): Lighter weight but operator
  unfamiliar; less enterprise-relevant for demos.
- Flux instead of ArgoCD: Comparable but ArgoCD's web UI aids learning
  and debugging.

### Primary SDLC Component Inventory

| Component | Tool | License | Helm Chart | Namespace |
|-----------|------|---------|------------|-----------|
| Source Control + PM | GitLab CE | MIT | `gitlab/gitlab` | `gitlab` |
| CI/CD Pipelines | Jenkins | MIT | `jenkins/jenkins` | `jenkins` |
| Container Registry | Harbor | Apache 2.0 | `harbor/harbor` | `harbor` |
| Metrics | Prometheus | Apache 2.0 | `prometheus-community/kube-prometheus-stack` | `monitoring` |
| Dashboards | Grafana | AGPL-3.0* | (bundled in kube-prometheus-stack) | `monitoring` |
| Logging | Loki | AGPL-3.0* | `grafana/loki-stack` | `logging` |
| Alerting | Alertmanager | Apache 2.0 | (bundled in kube-prometheus-stack) | `monitoring` |

### Secondary SDLC Component Inventory

| Component | Tool | License | Helm Chart | Namespace |
|-----------|------|---------|------------|-----------|
| Source Control | Gitea | MIT | `gitea-charts/gitea` | `gitea` |
| CI/CD | Woodpecker CI | Apache 2.0 | `woodpecker/woodpecker` | `woodpecker` |

\* AGPL-3.0 accepted per constitution Principle II exception for
dominant solution with no permissive alternative at comparable maturity.

### GitLab CE on Kubernetes — Considerations

The official `gitlab/gitlab` Helm chart is complex (~50 sub-charts
including PostgreSQL, Redis, Gitaly, Sidekiq, Webservice, etc.). Key
decisions:

- **Use the official Helm chart** despite complexity — it is well-tested
  and handles upgrades. The operator has 768GB RAM; resource constraints
  are not a concern.
- **Disable components already provided by k3s infra**: Use cluster
  cert-manager (not GitLab's bundled one), use Traefik ingress (not
  nginx), use external PostgreSQL if desired (or keep bundled).
- **Persistence**: All GitLab PVCs use Longhorn storage class.
- **Resource requests**: GitLab webservice ~4GB RAM, Gitaly ~2GB,
  Sidekiq ~2GB, PostgreSQL ~1GB, Redis ~512MB. Total ~10GB RAM minimum
  for GitLab alone — well within agent-01's 64GB.

### Jenkins on Kubernetes

- **Jenkins Helm chart** (`jenkins/jenkins`) deploys controller + agent
  pods.
- **Jenkins agents** run as ephemeral Kubernetes pods (scales to zero
  when idle).
- **Pipeline integration**: GitLab webhook triggers Jenkins via
  Generic Webhook Trigger plugin or GitLab plugin.
- **Artifact push**: Jenkins pipeline uses `docker push` to Harbor
  (credentials via Sealed Secret).

### Secret Management

**Decision**: SOPS + age for encrypting secrets in Git, Sealed Secrets
for Kubernetes-native secret management.

**Rationale**: SOPS (MPL-2.0) + age (BSD 3-Clause) provide file-level
encryption for secrets in Git repos. Sealed Secrets (Apache 2.0) provides
Kubernetes-native encrypted secrets that can be safely stored in GitOps
repositories.

**Alternatives considered**:
- HashiCorp Vault: Changed to BSL license. Rejected per Principle II.
- OpenBao (fork): Too early in development lifecycle. Deferred to
  future evaluation.

---

## DNS Strategy

### Current State

- External: NextDNS
- Internal: UniFi built-in DNS (limited custom records)
- No local DNS server for lab resolution

### Target State

Deploy CoreDNS (already bundled with k3s) as the authoritative DNS for
`home.lab` and `apps.home.lab` zones. Expose via MetalLB LoadBalancer
IP on VLAN 2. Configure UDMPRO DHCP to distribute CoreDNS IP as
primary DNS for VLAN 2 (lab-routed).

**Alternative**: Deploy a dedicated DNS VM or use Pi-hole/AdGuard Home.
Deferred — CoreDNS on k3s is simpler and aligns with Principle I
(DNS config as code via ConfigMap/CoreFile).

---

## Testing Strategy

### Per-Layer Test Types

| Layer | Test Type | Tool | Trigger |
|-------|-----------|------|---------|
| iLO Ansible | Lint | `ansible-lint`, `yamllint` | Pre-commit, CI |
| iLO Ansible | Syntax check | `ansible-playbook --syntax-check` | CI |
| iLO Ansible | Integration | Live iLO endpoint + assertions | Manual, scheduled |
| OpenTofu modules | Validate | `tofu validate` | Pre-commit, CI |
| OpenTofu modules | Lint | `tflint` (MPL-2.0) | Pre-commit, CI |
| OpenTofu modules | Plan review | `tofu plan` | CI on PR |
| OpenTofu modules | Integration | `tofu test` | CI, scheduled |
| k3s Ansible | Lint | `ansible-lint`, `yamllint` | Pre-commit, CI |
| k3s Ansible | Molecule | Molecule + Docker/Vagrant | CI |
| k3s cluster | Smoke test | `kubectl` assertions | Post-deploy |
| SDLC services | Health check | HTTP probes per service | Post-deploy, monitoring |
| End-to-end | Integration | Custom test suite (Makefile) | Scheduled, manual |

### Pre-commit Hooks

```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-tf
    hooks:
      - id: tofu_fmt
      - id: tofu_validate
      - id: tflint
  - repo: https://github.com/ansible/ansible-lint
    hooks:
      - id: ansible-lint
  - repo: https://github.com/pre-commit/pre-commit-hooks
    hooks:
      - id: detect-private-key
      - id: check-merge-conflict
      - id: trailing-whitespace
      - id: end-of-file-fixer
  - repo: https://github.com/koalaman/shellcheck-precommit
    hooks:
      - id: shellcheck
```
