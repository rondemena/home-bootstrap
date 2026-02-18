plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

config {
  # OpenTofu compatibility
  call_module_type = "local"
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}
