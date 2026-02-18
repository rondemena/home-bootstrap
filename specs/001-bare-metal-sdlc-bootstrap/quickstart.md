# Quickstart: Bare Metal SDLC Bootstrap

## Prerequisites

### Hardware

| Server | Required | Notes |
|--------|----------|-------|
| HPE DL380 Gen10 (iLO 5) | Yes (primary) | 40c, 768GB RAM, 8x 1.8TB. Proxmox already installed. |
| HPE DL360 Gen9 (iLO 4) | Optional (future) | 24c, 128GB RAM, 80+ TB storage. Role TBD. |

- iLO management on VLAN 5 (192.168.5.0/24), accessible from workstation
- Servers trunked to VLANs 2-5

### Network

- **Gateway**: UniFi Dream Machine Pro (UDMPRO) with fiber egress
- **Switches**: USW-24-PoE, USW-Flex, US-8
- **VLANs configured**: 1 (default), 2 (lab-routed), 3 (lab-clustering),
  4 (lab-storage), 5 (iLO), 201 (DMZ-A), 254 (guest)
- Static IPs reserved on VLAN 2 for:
  - Proxmox host: 192.168.2.11
  - k3s server VM: 192.168.2.100
  - k3s agent VMs: 192.168.2.200-201
  - MetalLB pool: 192.168.2.240-250
- DNS entries (or /etc/hosts) for `*.apps.home.lab` pointing to
  MetalLB range

### Workstation Software

```bash
# Required
sudo apt install python3 python3-pip ansible sshpass jq make

# Python dependencies
pip3 install proxmoxer requests redfish

# OpenTofu (see https://opentofu.org/docs/intro/install/)
# age (for SOPS secret encryption)
# sops
# kubeseal (for Sealed Secrets CLI)
# helm
# kubectl
```

### Pre-Deployment Checklist

- [ ] Export Kimai time tracking data from existing DL380 VMs
- [ ] Flush existing VMs on DL380 Proxmox
- [ ] Verify iLO access: `curl -k https://192.168.5.11/redfish/v1/`
- [ ] Verify Proxmox API: `curl -k https://192.168.2.11:8006/api2/json/version`
- [ ] Generate SSH key: `ssh-keygen -t ed25519`
- [ ] Set up SOPS age key (see Secrets Setup below)

### Secrets Setup

```bash
# Generate age key for SOPS
age-keygen -o ~/.config/sops/age/keys.txt

# Create .sops.yaml in repo root
cat > .sops.yaml << 'EOF'
creation_rules:
  - path_regex: \.enc\.ya?ml$
    age: >-
      YOUR_AGE_PUBLIC_KEY_HERE
EOF

# Create encrypted secrets file
sops code/ansible/inventory/group_vars/secrets.enc.yml
# Add: ilo_pass, pve_api_token_secret, etc.
```

## Full Bootstrap (Single Command)

```bash
make bootstrap
```

This runs all layers sequentially:
1. iLO provisioning (BIOS config — skips DL380 since Proxmox installed)
2. Proxmox host configuration (storage, network, templates)
3. VM provisioning (OpenTofu apply — 3 VMs on DL380)
4. k3s cluster installation (1 server + 2 agents)
5. Infrastructure services (MetalLB, Longhorn, cert-manager)
6. ArgoCD installation
7. Primary SDLC application sync (GitLab, Jenkins, Harbor, monitoring)
8. Secondary SDLC application sync (Gitea, Woodpecker)

## Layer-by-Layer Execution

### Layer 0: iLO Provisioning

```bash
# Configure BIOS on DL360g9 (skips DL380g10)
make provision-server HOST=192.168.5.12

# Verify
make test-ilo HOST=192.168.5.12
```

### Layer 1: Proxmox Configuration

```bash
# Configure storage, networking, cloud-init templates on DL380g10
make configure-proxmox

# Verify
make test-proxmox
```

### Layer 2: VM Provisioning

```bash
# Plan first (review changes)
make plan-vms

# Apply VM provisioning
make provision-vms

# Verify
make test-vms
```

### Layer 3: k3s Cluster

```bash
# Install k3s on VMs
make bootstrap-k3s

# Verify
make test-k3s
```

### Layer 4: SDLC Toolchain

```bash
# Deploy infrastructure services + ArgoCD
make deploy-infra

# Deploy primary + secondary SDLC applications via ArgoCD
make deploy-apps

# Verify
make test-apps
```

## Validation

```bash
# Run full end-to-end test suite
make test-e2e

# Run lint checks only (fast)
make lint

# Check all service health endpoints
make health-check
```

## Accessing Services

After successful bootstrap:

### Primary SDLC Stack

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| Proxmox | https://192.168.2.11:8006 | root / (set in answer.toml) |
| ArgoCD | https://argocd.apps.home.lab | admin / (auto-generated) |
| GitLab CE | https://gitlab.apps.home.lab | root / (auto-generated) |
| Jenkins | https://jenkins.apps.home.lab | admin / (in sealed secret) |
| Harbor | https://harbor.apps.home.lab | admin / (in sealed secret) |
| Grafana | https://grafana.apps.home.lab | admin / (in sealed secret) |
| Prometheus | https://prometheus.apps.home.lab | (no auth) |

### Secondary SDLC Stack (Learning)

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| Gitea | https://gitea.apps.home.lab | (first-run setup) |
| Woodpecker | https://ci.apps.home.lab | (OAuth via Gitea) |

## Teardown

```bash
# Destroy VMs only (keeps Proxmox)
make destroy-vms

# Full teardown (WARNING: destroys all VMs and k3s cluster)
make destroy-all
```

## Troubleshooting

### iLO unreachable

```bash
# Verify network connectivity to VLAN 5
ping 192.168.5.11
curl -k https://192.168.5.11/redfish/v1/

# Check iLO license level (important for DL360g9 / iLO 4)
make check-ilo-license HOST=192.168.5.12
```

### Proxmox API errors

```bash
# Test API connectivity on VLAN 2
curl -k https://192.168.2.11:8006/api2/json/version

# Verify API token permissions
make test-proxmox-auth
```

### k3s node not joining

```bash
# Check k3s service on the agent node
ssh admin@192.168.2.200 sudo systemctl status k3s-agent

# Check k3s logs
ssh admin@192.168.2.200 sudo journalctl -u k3s-agent -f

# Verify network connectivity to server on VLAN 2
ssh admin@192.168.2.200 curl -k https://192.168.2.100:6443/healthz
```

### ArgoCD sync failures

```bash
# Check ArgoCD application status
kubectl -n argocd get applications

# View sync details for GitLab
kubectl -n argocd describe application gitlab

# View sync details for Jenkins
kubectl -n argocd describe application jenkins
```

### GitLab not starting

```bash
# GitLab has many sub-pods; check all
kubectl -n gitlab get pods

# Check Gitaly (common bottleneck)
kubectl -n gitlab logs -l app=gitaly

# Check webservice
kubectl -n gitlab logs -l app=webservice
```
