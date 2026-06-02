resource "random_id" "acr" {
  byte_length = 4
}

resource "azurerm_container_registry" "main" {
  name                = "acrevhub${random_id.acr.hex}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
  tags                = local.common_tags
}
