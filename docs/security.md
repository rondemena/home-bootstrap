# Security Hardening Guide

## Pre-Deployment Checklist

- [ ] Generate SOPS age key: `age-keygen -o ~/.config/sops/age/keys.txt`
- [ ] Update .sops.yaml with your age public key
- [ ] Encrypt secrets: `sops code/ansible/inventory/group_vars/secrets.enc.yml`
- [ ] Verify no plaintext secrets in git: `git log --all --diff-filter=A -p -- '*.enc.*' | grep -v '^\+.*ENC\['`
- [ ] Verify pre-commit hooks active: `pre-commit run --all-files`

## Kubernetes Security

### RBAC
- k3s ships with RBAC enabled by default
- Service accounts created per-namespace by ArgoCD
- Jenkins service account scoped to jenkins namespace

### Network Policies
For namespace isolation, apply after deployment:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```
Apply per-namespace, then add allow rules for required traffic.

### Secret Rotation
- SOPS age key: Rotate annually. Re-encrypt all .enc.yml files.
- k3s token: Rotated via k3s server restart with new token.
- Harbor robot accounts: Rotate quarterly.
- GitLab API tokens: Rotate quarterly.
- Jenkins admin password: Rotate via Sealed Secret update.

## TLS
- Self-signed certificates via cert-manager (selfsigned-issuer)
- Upgrade path: Replace with Let's Encrypt ACME issuer when public DNS available
- Internal services communicate over cluster network (no TLS between pods)

## Proxmox
- API token scoped to minimal permissions (VM management only)
- No root SSH from automation (uses dedicated ansible-svc user)
- Firewall rules on Proxmox host limit management access to VLAN 2
