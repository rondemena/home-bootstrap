output "vm_id" {
  description = "The VM ID"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "vm_name" {
  description = "The VM name"
  value       = proxmox_virtual_environment_vm.vm.name
}

output "ip_address" {
  description = "The configured IP address"
  value       = var.ip_address
}

output "role" {
  description = "The VM role"
  value       = var.role
}
