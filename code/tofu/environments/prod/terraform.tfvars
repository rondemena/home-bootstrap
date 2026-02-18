# VM definitions per data-model.md
# DL380g10 — primary host (768GB RAM, 40c)
vm_definitions = {
  "k3s-server-01" = {
    vmid        = 100
    name        = "k3s-server-01"
    role        = "k3s-server"
    cores       = 8
    memory_mb   = 16384
    disk_gb     = 100
    ip_address  = "192.168.2.100/24"
    gateway     = "192.168.2.1"
    dns_servers = ["192.168.2.1"]
  }
  "k3s-agent-01" = {
    vmid        = 200
    name        = "k3s-agent-01"
    role        = "k3s-agent"
    cores       = 8
    memory_mb   = 65536
    disk_gb     = 200
    ip_address  = "192.168.2.200/24"
    gateway     = "192.168.2.1"
    dns_servers = ["192.168.2.1"]
  }
  "k3s-agent-02" = {
    vmid        = 201
    name        = "k3s-agent-02"
    role        = "k3s-agent"
    cores       = 8
    memory_mb   = 65536
    disk_gb     = 200
    ip_address  = "192.168.2.201/24"
    gateway     = "192.168.2.1"
    dns_servers = ["192.168.2.1"]
  }
}
