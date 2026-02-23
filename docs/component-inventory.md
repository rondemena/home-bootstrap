# Component Inventory

> **Satisfies**: FR-014 (Component Inventory) and Constitution Principle II
> (prefer permissive licenses; AGPL/GPL exceptions documented below).

## License Exception Notes

- **Ansible** (GPL-3.0-only): Accepted per Principle II -- no permissive
  alternative provides equivalent maturity for agentless configuration
  management at this scale.
- **Proxmox VE** (AGPL-3.0): Accepted per Principle II -- hypervisor runs
  on bare metal, is not modified, and is not distributed.
- **Grafana** (AGPL-3.0): Accepted per Principle II -- used internally for
  dashboards only; no modifications distributed.
- **Loki** (AGPL-3.0): Accepted per Principle II -- used internally for log
  aggregation only; no modifications distributed.

## Inventory Table

| Component | Version | License (SPDX) | Purpose | Stack | SDLC Phase |
|---|---|---|---|---|---|
| OpenTofu | >= 1.7 | MPL-2.0 | Infrastructure as Code | Infrastructure | Provision |
| Ansible | >= 2.16 | GPL-3.0-only | Configuration management | Infrastructure | Configure |
| k3s | v1.31.4+k3s1 | Apache-2.0 | Container orchestration | Infrastructure | Operate |
| Helm | >= 3.14 | Apache-2.0 | Kubernetes package manager | Infrastructure | Deploy |
| ArgoCD | >= 2.12 | Apache-2.0 | GitOps continuous delivery | Infrastructure | Deploy |
| GitLab CE | latest | MIT | Source control + project management | Primary | Code / Plan |
| Jenkins | latest LTS | MIT | CI/CD pipelines | Primary | Build / Test |
| Harbor | >= 2.11 | Apache-2.0 | Container registry | Primary | Release |
| Gitea | latest | MIT | Source control (lightweight) | Secondary | Code |
| Woodpecker CI | >= 2.7 | Apache-2.0 | CI/CD pipelines (lightweight) | Secondary | Build |
| Prometheus | latest | Apache-2.0 | Metrics collection | Primary | Monitor |
| Grafana | latest | AGPL-3.0 | Dashboards and visualization | Primary | Monitor |
| Loki | latest | AGPL-3.0 | Log aggregation | Primary | Monitor |
| Alertmanager | latest | Apache-2.0 | Alert routing and notification | Primary | Monitor |
| MetalLB | latest | Apache-2.0 | Bare-metal load balancer | Infrastructure | Operate |
| Longhorn | latest | Apache-2.0 | Distributed block storage | Infrastructure | Operate |
| cert-manager | latest | Apache-2.0 | TLS certificate management | Infrastructure | Operate |
| Sealed Secrets | latest | Apache-2.0 | Kubernetes secret encryption | Infrastructure | Operate |
| SOPS | latest | MPL-2.0 | File-level secret encryption | Infrastructure | Operate |
| age | latest | BSD-3-Clause | Encryption backend for SOPS | Infrastructure | Operate |
| Traefik | bundled w/ k3s | MIT | Ingress controller | Infrastructure | Operate |
| Proxmox VE | 8.3 | AGPL-3.0 | Hypervisor (bare metal) | Infrastructure | Operate |
| Ubuntu | 24.04 LTS | Various FOSS | VM operating system | Infrastructure | Operate |
| MinIO | latest | AGPL-3.0 | S3-compatible object storage | Infrastructure | Operate |
