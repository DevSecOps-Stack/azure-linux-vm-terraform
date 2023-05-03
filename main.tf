# Configure the Azure Provider
provider "azurerm" {
  # whilst the `version` attribute is optional, we recommend pinning to a given version of the Provider
  subscription_id = "205021e2-11c0-4939-8aa7-41c29b36b86f"
  client_id = "70fe070f-1c91-46d6-918e-6e8ff746efd5"
  client_secret = "Bto8Q~4YUQizHa.bOxj5DWrtds4_ALs7VyrSeb3x"
  tenant_id = "4c6f1364-8db1-4e57-95ef-b3cf7dd7d4c9"
  # version = "~> 2.54.0"
  features {}
}
data "azurerm_client_config" "current" {}
# Create a resource group
resource "azurerm_resource_group" "example_rg" {
  name     = "${var.resource_prefixes}-RG"
  location = var.node_location
}
locals {
  ssh_keygen_command = "ssh-keygen -t rsa -b 2048 -f ${path.module}/id_rsa -q -N ''"
  ssh_public_key = fileexists("${path.module}/id_rsa.pub") ? file("${path.module}/id_rsa.pub") : ""
  ssh_private_key = fileexists("${path.module}/id_rsa") ? file("${path.module}/id_rsa") : ""
}
resource "null_resource" "ssh_keygen" {
  provisioner "local-exec" {
    command = local.ssh_keygen_command
  }
   triggers = {
    public_key = local.ssh_public_key
    private_key = local.ssh_private_key
  }
}
resource "azurerm_key_vault" "example_rg" {
  name                = "${var.resource_prefixes}-KV"
  location            = azurerm_resource_group.example_rg.location
  resource_group_name = azurerm_resource_group.example_rg.name
  sku_name            = "standard"

  tenant_id = data.azurerm_client_config.current.tenant_id

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "get",
      "set",
      "delete",
      "list",
    ]
  }
}

resource "azurerm_key_vault_secret" "public_key" {
  depends_on = [null_resource.ssh_keygen]

  name         = "vm-ssh-public-key"
  value        = file("${path.module}/id_rsa.pub")
  key_vault_id = azurerm_key_vault.example_rg.id
}

resource "azurerm_key_vault_secret" "private_key" {
  depends_on = [null_resource.ssh_keygen]

  name         = "vm-ssh-private-key"
  value        = file("${path.module}/id_rsa")
  key_vault_id = azurerm_key_vault.example_rg.id
  
}

# Create a virtual network within the resource group
resource "azurerm_virtual_network" "example_vnet" {
  name                = "${var.resource_prefixes}-vnet"
  resource_group_name = azurerm_resource_group.example_rg.name
  location            = var.node_location
  address_space       = var.node_address_space
}

# Create a subnets within the virtual network
resource "azurerm_subnet" "example_subnet" {
  name                 = "${var.resource_prefixes}-subnet"
  resource_group_name  = azurerm_resource_group.example_rg.name
  virtual_network_name = azurerm_virtual_network.example_vnet.name
  address_prefixes     = var.node_address_prefixes
}

# Create Linux Public IP
resource "azurerm_public_ip" "example_public_ip" {
  count = var.node_count
  name  = "${var.resource_prefixes}-${format("%02d", count.index)}-PublicIP"
  #name = "${var.resource_prefix}-PublicIP"
  location            = azurerm_resource_group.example_rg.location
  resource_group_name = azurerm_resource_group.example_rg.name
  allocation_method   = var.Environment == "Test" ? "Static" : "Dynamic"

  tags = {
    environment = "Test"
  }
}



# Create Network Interface
resource "azurerm_network_interface" "example_nic" {
  count = var.node_count
  #name = "${var.resource_prefix}-NIC"
  name                = "${var.resource_prefixes}-${format("%02d", count.index)}-NIC"
  location            = azurerm_resource_group.example_rg.location
  resource_group_name = azurerm_resource_group.example_rg.name
  #

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.example_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = element(azurerm_public_ip.example_public_ip.*.id, count.index)
    #public_ip_address_id = azurerm_public_ip.example_public_ip.id
    #public_ip_address_id = azurerm_public_ip.example_public_ip.id
  }
}

# Creating resource NSG
resource "azurerm_network_security_group" "example_nsg" {

  name                = "${var.resource_prefixes}-NSG"
  location            = azurerm_resource_group.example_rg.location
  resource_group_name = azurerm_resource_group.example_rg.name

  # Security rule can also be defined with resource azurerm_network_security_rule, here just defining it inline.
  security_rule {
    name                       = "Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"

  }
  tags = {
    environment = "Test"
  }
}

# Subnet and NSG association
resource "azurerm_subnet_network_security_group_association" "example_subnet_nsg_association" {
  subnet_id                 = azurerm_subnet.example_subnet.id
  network_security_group_id = azurerm_network_security_group.example_nsg.id

}

# use existing log analytics workspace
data "azurerm_log_analytics_workspace" "example_log_analytics" {
  name                = "Logs-pd-hub"
  resource_group_name = "logs-pd-hub-rg"
}
resource "azurerm_virtual_machine_extension" "example" {
  count = var.node_count
  name                 = "example-extension"
  virtual_machine_id   =  azurerm_linux_virtual_machine.example_linux_vm[count.index].id
  publisher            = "Microsoft.EnterpriseCloud.Monitoring"
  type                 = "OmsAgentForLinux"
  type_handler_version = "1.13"
  settings             = <<SETTINGS
{
    "workspaceId": "${data.azurerm_log_analytics_workspace.example_log_analytics.workspace_id}"
}
SETTINGS
  protected_settings = <<PROTECTED_SETTINGS
    {
        "workspaceKey": "${data.azurerm_log_analytics_workspace.example_log_analytics.primary_shared_key}"
    }
PROTECTED_SETTINGS
}

# Virtual Machine Creation — Linux
resource "azurerm_linux_virtual_machine" "example_linux_vm" {
  count = var.node_count
  name  = "${var.resource_prefixes}-${format("%02d", count.index)}"
  #name = "${var.resource_prefix}-VM"
  location                      = azurerm_resource_group.example_rg.location
  resource_group_name           = azurerm_resource_group.example_rg.name
  network_interface_ids         = [element(azurerm_network_interface.example_nic.*.id, count.index)]
  size                          = "Standard_A1_v2"
  admin_username                = "adminuser"
  #key_vault_secret_id           = azurerm_key_vault_secret.private_key.id

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
  admin_ssh_key {
    username    = "adminuser"
    public_key  = azurerm_key_vault_secret.public_key.value
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  
  tags = {
    environment = "Test"
  }

}
