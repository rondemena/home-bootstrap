# Basic validation test for proxmox-vm module
# Run: tofu test -chdir=code/tofu/modules/proxmox-vm

variables {
  proxmox_node    = "pve-01"
  vmid            = 100
  name            = "test-vm"
  role            = "k3s-server"
  cores           = 4
  memory_mb       = 8192
  disk_gb         = 50
  ip_address      = "192.168.2.100/24"
  gateway         = "192.168.2.1"
  dns_servers     = ["192.168.2.1"]
  dns_domain      = "example.lab"
  storage_pool    = "local"
  network_bridge  = "vmbr0"
  vlan_id         = 2
  template_vmid   = 9000
  cloud_init_user = "admin"
  ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest test@test"
  cpu_type        = "x86-64-v2-AES"
  disk_format     = "raw"
  tags            = ["test"]
}

run "validate_variables" {
  command = plan

  # Plan should succeed (won't apply without real Proxmox)
  expect_failures = []
}
