# Composite for M4 — Entra directory roles.
#
# Only azuread + time. NO azurerm: directory roles live in Graph, not in Azure
# Resource Manager. There is no subscription involved.
#
# `time` is used to wait for Graph propagation before the role binding is set on
# a newly created group, same problem as in pim-for-groups.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
  }
}
