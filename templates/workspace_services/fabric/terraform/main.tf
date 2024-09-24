# MANUAL CONFIG
# - Fabric Capacity created
# - Enable SPN on Fabric
# - Give RP Fabric permissions



# Azure Provider source and version being used
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.84.0"
    }
    fabric = {
      source  = "d9876690-4c35-4427-8926-7841735f8e1f-bmfqgch2aafebndz.z01.azurefd.net/microsoft/fabric"
      version = "0.1.0-alpha.8"
    }
  }

  backend "azurerm" {}
}

provider "fabric" {
  use_msi   = true
  tenant_id = "1bcdd767-61d6-48b1-8507-38d4d044a174" #TODO
}

provider "azurerm" {
  features {
    key_vault {
      # Don't purge on destroy (this would fail due to purge protection being enabled on keyvault)
      purge_soft_delete_on_destroy               = false
      purge_soft_deleted_secrets_on_destroy      = false
      purge_soft_deleted_certificates_on_destroy = false
      purge_soft_deleted_keys_on_destroy         = false
      # When recreating an environment, recover any previously soft deleted secrets - set to true by default
      recover_soft_deleted_key_vaults   = true
      recover_soft_deleted_secrets      = true
      recover_soft_deleted_certificates = true
      recover_soft_deleted_keys         = true
    }
  }
}

module "terraform_azurerm_environment_configuration" {
  source          = "git::https://github.com/microsoft/terraform-azurerm-environment-configuration.git?ref=0.6.0"
  arm_environment = var.arm_environment
}


data "azurerm_resource_group" "ws" {
  name = "rg-${var.tre_id}-ws-${local.short_workspace_id}"
}

data "azurerm_virtual_network" "ws" {
  name                = "vnet-${var.tre_id}-ws-${local.short_workspace_id}"
  resource_group_name = "rg-${var.tre_id}-ws-${local.short_workspace_id}"
}

data "azurerm_key_vault" "ws" {
  name                = local.keyvault_name
  resource_group_name = data.azurerm_resource_group.ws.name
}

data "azurerm_subnet" "services" {
  name                 = "ServicesSubnet"
  virtual_network_name = data.azurerm_virtual_network.ws.name
  resource_group_name  = data.azurerm_resource_group.ws.name
}
