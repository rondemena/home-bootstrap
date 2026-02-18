provider "proxmox" {
  endpoint = var.proxmox_api_url
  insecure = var.proxmox_insecure

  api_token = var.proxmox_api_token
}

module "k3s_vms" {
  source   = "../../modules/proxmox-vm"
  for_each = var.vm_definitions

  proxmox_node    = var.proxmox_node
  vmid            = each.value.vmid
  name            = each.value.name
  role            = each.value.role
  cores           = each.value.cores
  memory_mb       = each.value.memory_mb
  disk_gb         = each.value.disk_gb
  ip_address      = each.value.ip_address
  gateway         = each.value.gateway
  dns_servers     = each.value.dns_servers
  storage_pool    = each.value.storage_pool
  network_bridge  = each.value.network_bridge
  vlan_id         = each.value.vlan_id
  template_vmid   = each.value.template_vmid
  cloud_init_user = each.value.cloud_init_user
  ssh_public_key  = var.ssh_public_key
}
