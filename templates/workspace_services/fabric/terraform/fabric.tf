# fabric workspace

# Workspace with Capacity and Identity
data "fabric_capacity" "capacity" {
  display_name = "damoo"
}

resource "fabric_workspace" "workspace" {
  display_name = "tre-test-manual"
  description  = "Example Workspace 2"
  capacity_id  = data.fabric_capacity.capacity.id
  identity = {
    type = "SystemAssigned"
  }
}

# resource "fabric_workspace_role_assignment" "example" {
#   workspace_id   = "00000000-0000-0000-0000-000000000000"
#   principal_id   = "11111111-1111-1111-1111-111111111111"
#   principal_type = "User"
#   role           = "Member"
# }
