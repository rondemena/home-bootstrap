# Proxmox VM module
# Creates a VM from a cloud-init template with configurable resources

resource "proxmox_virtual_environment_vm" "vm" {
  node_name = var.proxmox_node
  vm_id     = var.vmid
  name      = var.name

  description = "Managed by OpenTofu - role: ${var.role}"

  tags = [var.role, "managed-by-tofu"]

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  cpu {
    cores = var.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    interface    = "scsi0"
    size         = var.disk_gb
    datastore_id = var.storage_pool
    file_format  = "raw"
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.vlan_id
    model   = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = "home.lab"
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
