variable "proxmox_api_url" {
  description = "Proxmox API endpoint URL"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in format user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for Proxmox API (self-signed certs)"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name to create VMs on"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init user"
  type        = string
}

variable "dns_domain" {
  description = "DNS search domain for cloud-init VMs"
  type        = string
  default     = ""
}

variable "vm_definitions" {
  description = "Map of VM definitions to create"
  type = map(object({
    vmid            = number
    name            = string
    role            = string
    cores           = number
    memory_mb       = number
    disk_gb         = number
    ip_address      = string
    gateway         = string
    dns_servers     = list(string)
    storage_pool    = optional(string, "local")
    network_bridge  = optional(string, "vmbr0")
    vlan_id         = optional(number, 0)
    template_vmid   = optional(number, 9000)
    cloud_init_user = optional(string, "admin")
    cpu_type        = optional(string, "x86-64-v2-AES")
    disk_format     = optional(string, "raw")
    tags            = optional(list(string), [])
  }))
}
