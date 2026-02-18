# Contract: Layer Interfaces

**Version**: 2.0.0
**Date**: 2026-02-17

## Purpose

Defines the interfaces between each bootstrap layer so that layers
can be developed, tested, and executed independently.

## Layer Dependency Chain

```
Layer 0: iLO → Layer 1: Proxmox Host → Layer 2: VMs → Layer 3: k3s → Layer 4: SDLC Apps
```

Each layer produces outputs consumed by the next layer's inputs.

---

## Layer 0 → Layer 1: iLO to Proxmox Host

**Trigger**: `make provision-server HOST=<ilo-ip>`
**Playbook**: `ansible/playbooks/00-ilo-provision.yml`

**Note**: DL380g10 already has Proxmox installed — this layer is
primarily needed for DL360g9. The playbook checks
`proxmox_already_installed` and skips if true.

### Inputs (from inventory)

| Input | Source | Format |
|-------|--------|--------|
| iLO endpoint | `ilo_host` inventory var | IPv4 (VLAN 5) |
| iLO credentials | SOPS vault | string |
| iLO version | `ilo_version` inventory var | enum |
| BIOS settings | `roles/ilo_provision/defaults/main.yml` | YAML dict |
| Proxmox ISO URL | `proxmox_iso_url` inventory var | HTTP URL |
| Answer file | `ansible/files/proxmox-answer-*.toml` | TOML |

### Outputs (verified by Layer 1)

| Output | Verification Method | Expected Value |
|--------|---------------------|----------------|
| Proxmox VE installed | SSH reachable on port 22 | connection success |
| Proxmox API available | HTTPS GET `192.168.2.x:8006/api2/json/version` | HTTP 200 |
| BIOS VT-x enabled | `redfish_info` BIOS query | `Enabled` |
| BIOS VT-d enabled | `redfish_info` BIOS query | `Enabled` |
| Boot mode | `redfish_info` BIOS query | `Uefi` |

### Idempotency Contract

- If `proxmox_already_installed: true`, skip entire provisioning
- If Proxmox API responds, skip ISO mount and reboot
- BIOS settings: only apply if current value differs from desired
- Virtual media: only mount if not already mounted with correct ISO
- iLO 4 without Advanced license: skip virtual media, warn operator

---

## Layer 1 → Layer 2: Proxmox Host to VMs

**Trigger**: `make configure-proxmox` then `make provision-vms`
**Playbook**: `ansible/playbooks/01-proxmox-configure.yml`
**OpenTofu**: `tofu -chdir=code/tofu/environments/prod apply`

### Inputs (from Layer 0 outputs + inventory)

| Input | Source | Format |
|-------|--------|--------|
| Proxmox API endpoint | `pve_api_host` inventory var | `https://192.168.2.11:8006/` |
| API credentials | SOPS vault | API token |
| VM definitions | `tofu/environments/prod/terraform.tfvars` | HCL |
| Cloud-init template | `ansible/playbooks/02-cloud-image-template.yml` | VMID 9000 |
| SSH public key | `~/.ssh/id_ed25519.pub` | SSH key |

### Outputs (verified by Layer 2)

| Output | Verification Method | Expected Value |
|--------|---------------------|----------------|
| VMs created | `tofu state list` | all VMs present |
| VMs running | Proxmox API status query | `status: running` |
| SSH accessible | `ssh admin@192.168.2.x hostname` | correct hostname |
| Cloud-init complete | `/var/lib/cloud/instance/boot-finished` exists | file exists |
| Correct IP assigned | `ip addr show` on guest | matches tfvars |
| VLAN 2 connectivity | ping gateway 192.168.2.1 from guest | success |

### Idempotency Contract

- `tofu plan` shows zero changes when VMs match desired state
- Cloud-init template creation: skips if template VMID 9000 exists
- Network bridge creation: skips if bridge already exists

---

## Layer 2 → Layer 3: VMs to k3s Cluster

**Trigger**: `make bootstrap-k3s`
**Playbook**: `ansible/playbooks/03-k3s-install.yml`

### Inputs (from Layer 1 outputs + inventory)

| Input | Source | Format |
|-------|--------|--------|
| VM IPs | `ansible_host` per k3s group host | IPv4 (VLAN 2) |
| SSH access | key-based auth via cloud-init | SSH key |
| k3s version | `k3s_version` group var | semver tag |
| k3s config | `k3s_server`/`k3s_agent` group vars | YAML |

### Outputs (verified by Layer 3)

| Output | Verification Method | Expected Value |
|--------|---------------------|----------------|
| k3s server running | `systemctl is-active k3s` on 192.168.2.100 | `active` |
| k3s agents joined | `kubectl get nodes` | all nodes Ready |
| kubeconfig available | `~/.kube/config` on control node | valid kubeconfig |
| CoreDNS running | `kubectl -n kube-system get pods` | Running |
| Traefik running | `kubectl -n kube-system get pods` | Running |

### Idempotency Contract

- k3s install script is idempotent (re-runs are safe)
- Ansible role checks if k3s is already installed at correct version
- Agent join: skips if node is already a cluster member

---

## Layer 3 → Layer 4: k3s to SDLC Applications

**Trigger**: `make deploy-infra` then `make deploy-apps`
**Playbook**: `ansible/playbooks/04-k3s-post-install.yml` (infra)
**GitOps**: ArgoCD syncs from `code/k8s/` directory

### Inputs (from Layer 2 outputs)

| Input | Source | Format |
|-------|--------|--------|
| kubeconfig | Layer 2 output | YAML file |
| Helm values | `code/k8s/infrastructure/*/values.yaml` | YAML |
| ArgoCD app manifests | `code/k8s/argocd/applications/*.yaml` | K8s YAML |
| Sealed Secrets key | generated on first deploy | K8s Secret |

### Phase 3a: Infrastructure Services (pre-ArgoCD)

Deployed via Helm directly (ArgoCD not yet available):

| Service | Verification | Expected |
|---------|-------------|----------|
| MetalLB | `kubectl -n metallb-system get pods` | Running |
| MetalLB pool | Create test LoadBalancer Service | IP from 192.168.2.240-250 |
| Longhorn | `kubectl -n longhorn-system get pods` | Running |
| cert-manager | `kubectl -n cert-manager get pods` | Running |
| Sealed Secrets | `kubectl -n kube-system get pods` | Running |

### Phase 3b: ArgoCD + Primary SDLC Applications

| Service | Verification | Expected |
|---------|-------------|----------|
| ArgoCD | `https://argocd.apps.home.lab` | login page |
| GitLab CE | `https://gitlab.apps.home.lab/-/health` | HTTP 200 |
| Jenkins | `https://jenkins.apps.home.lab/login` | HTTP 200 |
| Harbor | `https://harbor.apps.home.lab/api/v2.0/health` | HTTP 200 |
| Prometheus | `https://prometheus.apps.home.lab/-/healthy` | HTTP 200 |
| Grafana | `https://grafana.apps.home.lab/api/health` | HTTP 200 |
| Loki | `https://loki.apps.home.lab/ready` | HTTP 200 |

### Phase 3c: Secondary SDLC Applications (SHOULD)

| Service | Verification | Expected |
|---------|-------------|----------|
| Gitea | `https://gitea.apps.home.lab/api/healthz` | HTTP 200 |
| Woodpecker | `https://ci.apps.home.lab/healthz` | HTTP 200 |

### Idempotency Contract

- ArgoCD reconciliation loop handles drift automatically
- Helm upgrades are idempotent (same values = no changes)
- Sealed Secrets controller key: generated once, persisted in backup
