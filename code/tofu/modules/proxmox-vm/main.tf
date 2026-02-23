# Proxmox VM module
# Creates a VM from a cloud-init template with configurable resources

resource "proxmox_virtual_environment_vm" "vm" {
  node_name = var.proxmox_node
  vm_id     = var.vmid
  name      = var.name

  description = "Managed by OpenTofu - role: ${var.role}"

  tags = concat([var.role, "managed-by-tofu"], var.tags)

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    interface    = "scsi0"
    size         = var.disk_gb
    datastore_id = var.storage_pool
    file_format  = var.disk_format
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.vlan_id > 0 ? var.vlan_id : null
    model   = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dynamic "dns" {
      for_each = length(var.dns_servers) > 0 ? [1] : []
      content {
        servers = var.dns_servers
        domain  = var.dns_domain != "" ? var.dns_domain : null
      }
    }

    user_account {
      username = var.cloud_init_user
      keys     = [var.ssh_public_key]
    }
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    ignore_changes = [
      initialization,
      description,
    ]
  }
}
