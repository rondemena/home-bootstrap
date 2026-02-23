# Data Model: Bare Metal SDLC Bootstrap

**Date**: 2026-02-17 (revised from 2026-02-14)

## Entity Relationship Overview

```
Server 1──1 Hypervisor 1──* VM *──1 Cluster 1──* Service
  │                          │         │
  └── iLO endpoint           │         └── Namespace
                              │
                              └── role: k3s-server | k3s-agent | utility
```

## Entities

### Server

Represents a physical HPE server with out-of-band management.

| Attribute | Type | Constraints | Example |
|-----------|------|-------------|---------|
| name | string | unique, DNS-safe | `hpe-dl380g10` |
| ilo_ip | IPv4 | VLAN 5, reachable from control node | `192.168.5.11` |
| ilo_user | string | service account | `ansible-svc` |
| ilo_password | secret | managed via SOPS | (encrypted) |
| ilo_version | enum | `ilo4`, `ilo5`, `ilo6` | `ilo5` |
| model | string | informational | `DL380 Gen10` |
| cpu_spec | string | informational | `2x Xeon Gold 6148 (40c)` |
| ram_gb | int | total installed | `768` |
| disk_spec | string | informational | `8x 1.8TB (HW RAID)` |
| bios_profile | string | Proxmox-optimized preset | `virtualization` |
| boot_mode | enum | `uefi`, `legacy` | `uefi` |
| desired_os | string | target OS for installation | `proxmox-ve-8.3` |

**Actual instances**:

| name | model | iLO | CPU | RAM | Disk | Status |
|------|-------|-----|-----|-----|------|--------|
| hpe-dl380g10 | DL380 Gen10 | iLO 5 (192.168.5.11) | 2x Gold 6148 (40c) | 768GB | 8x 1.8TB (HW RAID) | Proxmox installed |
| hpe-dl360g9 | DL360 Gen9 | iLO 4 (192.168.5.12) | 2x E5-2690 v3 (24c) | 128GB | 8x 4TB + 4x 12TB | Not provisioned |

**State transitions**:
```
unprovisioned → bios_configured → os_installing → os_installed → ready
```

**Validation rules**:
- `ilo_ip` MUST be on VLAN 5 (192.168.5.0/24) and reachable via HTTPS port 443
- `ilo_version` = `ilo4` triggers Advanced license check for virtual media
- `ilo_version` >= `ilo5` uses Standard license (free) for all operations
- `boot_mode` MUST be `uefi` for Proxmox VE 8+

### Hypervisor

Represents a Proxmox VE instance running on a Server.

| Attribute | Type | Constraints | Example |
|-----------|------|-------------|---------|
| hostname | string | FQDN, unique in cluster | `pve-01.home.lab` |
| management_ip | IPv4 | VLAN 2, static | `192.168.2.11` |
| api_port | int | default 8006 | `8006` |
| api_token_id | string | Proxmox API token | `automation@pam!tofu` |
| api_token_secret | secret | managed via SOPS | (encrypted) |
| storage_pools | list[StoragePool] | at least 1 | see below |
| network_bridges | list[NetworkBridge] | at least `vmbr0` | see below |
| cluster_name | string | nullable if standalone | `homelab` |

**Sub-entity: StoragePool**

| Attribute | Type | Example |
|-----------|------|---------|
| name | string | `local` |
| type | enum: `dir`, `zfspool`, `lvmthin`, `nfs` | `dir` |
| pool | string (path or pool name) | `/var/lib/vz` |
| content | list[enum] | `["images", "rootdir", "iso"]` |

**Sub-entity: NetworkBridge**

| Attribute | Type | Example |
|-----------|------|---------|
| name | string | `vmbr0` |
| ports | list[string] | `["eno1"]` |
| cidr | string | `192.168.2.11/24` |
| gateway | IPv4 (nullable) | `192.168.2.1` |
| vlan_aware | bool | `true` |

**State transitions**:
```
installed → configured → cluster_member → ready
```

### VM

Represents a virtual machine on a Proxmox hypervisor.

| Attribute | Type | Constraints | Example |
|-----------|------|-------------|---------|
| vmid | int | unique cluster-wide | `200` |
| name | string | DNS-safe, unique | `k3s-agent-01` |
| node | string | Proxmox node name | `pve-01` |
| role | enum | `k3s-server`, `k3s-agent`, `utility` | `k3s-agent` |
| cpu_cores | int | >= 2 | `8` |
| memory_mb | int | >= 2048 | `65536` |
| disk_gb | int | >= 20 | `200` |
| storage_pool | string | must exist on node | `local` |
| network_bridge | string | must exist on node | `vmbr0` |
| vlan_id | int | VLAN tag for primary NIC | `2` |
| ip_address | IPv4 | VLAN 2, static, unique | `192.168.2.200` |
| gateway | IPv4 | VLAN 2 gateway | `192.168.2.1` |
| dns_servers | list[IPv4] | at least 1 | `["192.168.2.1"]` |
| ssh_public_key | string | Ed25519 or RSA | (key content) |
| cloud_init_user | string | default login | `admin` |
| template_vmid | int | cloud-init template | `9000` |

**State transitions**:
```
planned → provisioned → cloud_init_complete → k3s_joined → ready
```

**Validation rules**:
- `vmid` MUST NOT conflict with existing VMs on the cluster
- `vmid` for k3s servers MUST be in range 100-109
- `vmid` for k3s agents MUST be in range 200-229
- `vmid` for utility VMs MUST be in range 130-149
- `ip_address` MUST be on VLAN 2 (192.168.2.0/24) and outside DHCP range
- `memory_mb` >= 16384 for k3s-server role
- `memory_mb` >= 32768 for k3s-agent role (GitLab/observability)
- `disk_gb` >= 100 for k3s-server, >= 200 for k3s-agent (Longhorn + app data)

### Cluster

Represents a k3s Kubernetes cluster.

| Attribute | Type | Constraints | Example |
|-----------|------|-------------|---------|
| name | string | unique | `homelab` |
| server_url | URL | k3s API endpoint | `https://192.168.2.100:6443` |
| token | secret | join token, SOPS-managed | (encrypted) |
| version | string | pinned k3s release | `v1.31.4+k3s1` |
| server_nodes | list[VM] | >= 1 (3 for HA) | `[k3s-server-01]` |
| agent_nodes | list[VM] | >= 0 | `[k3s-agent-01, k3s-agent-02]` |
| metallb_ip_range | string | VLAN 2 pool for LoadBalancer | `192.168.2.240-192.168.2.250` |
| ingress_domain | string | wildcard DNS base | `*.apps.home.lab` |
| storage_class | string | default StorageClass | `longhorn` |

**State transitions**:
```
planned → server_installed → agents_joined → infra_deployed → apps_deployed → ready
```

### Service

Represents an SDLC application deployed on the Cluster.

| Attribute | Type | Constraints | Example |
|-----------|------|-------------|---------|
| name | string | unique per cluster | `gitlab` |
| namespace | string | Kubernetes namespace | `gitlab` |
| chart_repo | string | Helm repository URL | `https://charts.gitlab.io/` |
| chart_name | string | Helm chart name | `gitlab` |
| chart_version | string | pinned version | `8.7.0` |
| values_file | string | path to values.yaml | `k8s/apps/gitlab/values.yaml` |
| ingress_host | string | FQDN for access | `gitlab.apps.home.lab` |
| health_endpoint | string | HTTP health check path | `/-/health` |
| health_port | int | service port | `443` |
| license | string | SPDX identifier | `MIT` |
| sdlc_phase | enum | Plan, Code, Build, Test, Release, Deploy, Operate, Monitor | `Code` |
| stack | enum | `primary`, `secondary` | `primary` |
| depends_on | list[string] | service dependencies | `["sealed-secrets", "longhorn"]` |

**State transitions**:
```
defined → syncing → healthy → degraded → healthy (reconciliation loop)
```

## VMID Allocation Scheme

| Range | Purpose |
|-------|---------|
| 9000-9099 | Cloud-init templates |
| 100-109 | k3s server nodes |
| 130-149 | Utility VMs |
| 150-199 | Reserved for future use |
| 200-229 | k3s agent nodes |

## Network Allocation Scheme

| VLAN | Subnet | Purpose |
|------|--------|---------|
| 1 | 192.168.1.0/24 | Default / management clients |
| 2 | 192.168.2.0/24 | Lab-routed (k3s VMs, services) |
| 3 | 192.168.3.0/24 | Lab-clustering (k3s inter-node, Longhorn) |
| 4 | 192.168.4.0/24 | Lab-storage (NFS, Ceph, bulk I/O) |
| 5 | 192.168.5.0/24 | iLO out-of-band management |
| 201 | 192.168.201.0/24 | DMZ-A (externally reachable services) |
| 254 | 192.168.254.0/24 | Guest network |
| -- | 10.42.0.0/16 | k3s pod CIDR (default) |
| -- | 10.43.0.0/16 | k3s service CIDR (default) |

### IP Allocation — VLAN 2 (lab-routed)

| Range | Purpose |
|-------|---------|
| 192.168.2.1 | Gateway (UDMPRO) |
| 192.168.2.11-20 | Proxmox host management IPs |
| 192.168.2.100-109 | k3s server VMs (static, matches VMID 100s) |
| 192.168.2.130-149 | Utility VMs (static, matches VMID 130s) |
| 192.168.2.200-229 | k3s agent VMs (static, matches VMID 200s) |
| 192.168.2.240-250 | MetalLB LoadBalancer pool |

### IP Allocation — VLAN 5 (iLO management)

| Range | Purpose |
|-------|---------|
| 192.168.5.1 | Gateway (UDMPRO) |
| 192.168.5.11 | DL380g10 iLO |
| 192.168.5.12 | DL360g9 iLO |
