# Composite for Azure. Pulls in azurerm because it calls azure-rbac-on-group.
#
# NOTE: no `time` here. This module no longer calls pim-for-groups — the Azure
# groups are not PIM-managed, so there is no Graph propagation to wait for.
# pim-for-groups declares `time` itself and is used by the M3 path.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
