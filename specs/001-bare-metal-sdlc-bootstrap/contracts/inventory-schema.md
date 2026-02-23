# Contract: Ansible Inventory Schema

**Version**: 2.0.0
**Date**: 2026-02-17

## Purpose

Defines the structure and required variables for the Ansible inventory
that drives all provisioning layers. This contract ensures consistency
between the Ansible playbooks and OpenTofu configurations.

## Inventory File: `hosts.yml`

```yaml
---
all:
  vars:
    ansible_user: admin
    ansible_ssh_private_key_file: ~/.ssh/id_ed25519
    domain: home.lab
    dns_servers:
      - 192.168.2.1
    ntp_servers:
      - pool.ntp.org

  children:
    ilo_targets:
      hosts:
        hpe-dl380g10:
          ilo_host: 192.168.5.11
          ilo_user: ansible-svc
          # ilo_pass loaded from SOPS-encrypted vault
          ilo_version: ilo5
          server_model: "DL380 Gen10"
          proxmox_answer_file: proxmox-answer-dl380.toml
          proxmox_iso_url: "http://fileserver.home.lab/proxmox-ve_8.3-1.iso"
          proxmox_already_installed: true
        hpe-dl360g9:
          ilo_host: 192.168.5.12
          ilo_user: ansible-svc
          # ilo_pass loaded from SOPS-encrypted vault
          ilo_version: ilo4
          server_model: "DL360 Gen9"
          proxmox_answer_file: proxmox-answer-dl360.toml
          proxmox_iso_url: "http://fileserver.home.lab/proxmox-ve_8.3-1.iso"
          proxmox_already_installed: false
          ilo_advanced_license: false  # Set true if Advanced license available

    proxmox:
      hosts:
        pve-01:
          ansible_host: 192.168.2.11
          pve_api_host: 192.168.2.11
          pve_api_user: automation@pam
          # pve_api_token_id and pve_api_token_secret from SOPS
          pve_cluster_name: homelab
          pve_storage_pools:
            - name: local
              type: dir
              path: /var/lib/vz
              content: [images, rootdir, iso, snippets]

    k3s_server:
      hosts:
        k3s-server-01:
          ansible_host: 192.168.2.100
          k3s_role: server
          vmid: 100

    k3s_agent:
      hosts:
        k3s-agent-01:
          ansible_host: 192.168.2.200
          k3s_role: agent
          vmid: 200
        k3s-agent-02:
          ansible_host: 192.168.2.201
          k3s_role: agent
          vmid: 201

    k3s_cluster:
      children:
        k3s_server:
        k3s_agent:
      vars:
        k3s_version: "v1.31.4+k3s1"
        k3s_server_url: "https://192.168.2.100:6443"
        metallb_ip_range: "192.168.2.240-192.168.2.250"
        ingress_domain: "apps.home.lab"
```

## Required Variables by Group

### `ilo_targets`

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `ilo_host` | IPv4 | yes | iLO management IP (VLAN 5) |
| `ilo_user` | string | yes | iLO service account username |
| `ilo_version` | enum | yes | `ilo4`, `ilo5`, `ilo6` |
| `proxmox_iso_url` | URL | yes | HTTP/HTTPS URL to Proxmox ISO |
| `proxmox_answer_file` | string | yes | Filename in `ansible/files/` |
| `proxmox_already_installed` | bool | yes | Skip provisioning if true |
| `ilo_advanced_license` | bool | no | iLO 4 only: enables virtual media scripting |

### `proxmox`

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `pve_api_host` | IPv4 | yes | Proxmox API endpoint IP (VLAN 2) |
| `pve_api_user` | string | yes | Proxmox API username@realm |
| `pve_cluster_name` | string | no | Cluster name (null = standalone) |
| `pve_storage_pools` | list | yes | Storage pool definitions |

### `k3s_cluster`

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `k3s_version` | string | yes | Pinned k3s release tag |
| `k3s_server_url` | URL | yes | k3s API server endpoint (VLAN 2) |
| `metallb_ip_range` | string | yes | IP range for MetalLB (VLAN 2) |
| `ingress_domain` | string | yes | Base domain for ingress |

## Validation Rules

1. All `ilo_host` values MUST be on VLAN 5 (192.168.5.0/24) and unique
2. All `ansible_host` values MUST be on VLAN 2 (192.168.2.0/24) and unique
3. `vmid` for k3s servers MUST be in range 100-109
4. `vmid` for k3s agents MUST be in range 200-229
5. `k3s_server` group MUST have exactly 1 host (or 3 for HA)
6. `k3s_agent` group MUST have >= 0 hosts
7. Secrets (`ilo_pass`, `pve_api_token_secret`, `k3s_token`) MUST be
   loaded from SOPS-encrypted files, never inline in inventory
8. `metallb_ip_range` MUST NOT overlap with any static VM IPs
