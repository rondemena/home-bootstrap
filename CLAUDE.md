# home-bootstrap Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-02-17

## Active Technologies

- HCL (OpenTofu >= 1.7), YAML (Ansible >= 2.16), Groovy (Jenkinsfile) (001-bare-metal-sdlc-bootstrap)
- OpenTofu, Ansible, k3s, Helm, ArgoCD, GitLab CE, Jenkins, Harbor (001-bare-metal-sdlc-bootstrap)
- Hardware RAID on DL380g10 (Proxmox host), Longhorn on k3s (001-bare-metal-sdlc-bootstrap)

## Project Structure

```text
code/
  ansible/    # Playbooks, roles, inventory
  tofu/       # OpenTofu modules and environments
  k8s/        # Helm values, ArgoCD applications
  scripts/    # Bootstrap and test orchestration
tests/
  ansible/    # Lint and Molecule tests
  tofu/       # Integration tests
  k8s/        # Smoke tests
  e2e/        # End-to-end validation
```

## Commands

```bash
make bootstrap          # Full end-to-end bootstrap
make provision-server   # iLO BIOS config + Proxmox install
make configure-proxmox  # Proxmox host setup
make plan-vms           # OpenTofu plan (review changes)
make provision-vms      # OpenTofu apply (create VMs)
make bootstrap-k3s      # Install k3s cluster
make deploy-infra       # Deploy MetalLB, Longhorn, cert-manager
make deploy-apps        # Deploy SDLC apps via ArgoCD
make lint               # Run all linters
make test-e2e           # Run full test suite
make health-check       # Check all service endpoints
```

## Code Style

- HCL: `tofu fmt` standard formatting
- YAML: 2-space indent, ansible-lint + yamllint
- Bash: shellcheck compliant
- Groovy (Jenkinsfile): declarative pipeline syntax preferred

## Recent Changes

- 001-bare-metal-sdlc-bootstrap: Regenerated plan with corrected hardware (DL380g10 + DL360g9), VLAN networking (192.168.x.x), dual SDLC stack (GitLab+Jenkins primary, Gitea+Woodpecker secondary)

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->
