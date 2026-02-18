variable "proxmox_node" {
  description = "Proxmox node name to create the VM on"
  type        = string
}

variable "vmid" {
  description = "VM ID (unique cluster-wide)"
  type        = number

  validation {
    condition     = var.vmid >= 100 && var.vmid <= 999
    error_message = "VMID must be between 100 and 999."
  }
}

variable "name" {
  description = "VM hostname (DNS-safe)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name))
    error_message = "VM name must be DNS-safe (lowercase alphanumeric and hyphens)."
  }
}

variable "role" {
  description = "VM role for tagging and identification"
  type        = string

  validation {
    condition     = contains(["k3s-server", "k3s-agent", "utility"], var.role)
    error_message = "Role must be one of: k3s-server, k3s-agent, utility."
  }
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 4

  validation {
    condition     = var.cores >= 2
    error_message = "Minimum 2 CPU cores required."
  }
}

variable "memory_mb" {
  description = "Memory in MB"
  type        = number
  default     = 4096

  validation {
    condition     = var.memory_mb >= 2048
    error_message = "Minimum 2048 MB memory required."
  }
}

variable "disk_gb" {
  description = "Disk size in GB"
  type        = number
  default     = 50

  validation {
    condition     = var.disk_gb >= 20
    error_message = "Minimum 20 GB disk required."
  }
}

variable "ip_address" {
  description = "Static IP address in CIDR notation (e.g., 192.168.2.100/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
}

variable "dns_servers" {
  description = "List of DNS server IPs"
  type        = list(string)
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disk"
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the network interface"
  type        = number
  default     = 2
}

variable "template_vmid" {
  description = "VMID of the cloud-init template to clone from"
  type        = number
  default     = 9000
}

variable "cloud_init_user" {
  description = "Cloud-init default user"
  type        = string
  default     = "admin"
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init user"
  type        = string
}
