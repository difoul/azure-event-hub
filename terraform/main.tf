locals {
  common_tags = {
    environment = "demo"
    project     = "container-app-event-hub"
    managed-by  = "terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}
