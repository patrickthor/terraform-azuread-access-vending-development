# ==============================================================================
# Providers, backend and version requirements
#
# Provider configuration lives HERE, in the root — not in the module. A reusable
# module with its own provider blocks cannot be used with count, for_each or
# depends_on, so modules/access-vending deliberately has none.
#
# Constraints use `~>` here. The module itself uses `>=` so it never becomes a
# ceiling for consumers; a root configuration has a lockfile and a single owner,
# so pinning is safe and desirable.
#
# required_version >= 1.9 is a hard floor: the module's validations use
# cross-variable references, a 1.9 feature. On 1.5-1.8 the configuration fails
# with "Invalid reference in variable validation" before anything else runs.
# ==============================================================================

terraform {
  required_version = ">= 1.9"

  # Partial backend — the workflow generates backend.hcl from GitHub variables.
  # Locally:
  #   terraform init -backend-config=backend.hcl
  #
  # State contains subscription IDs, group object IDs, UPNs and full PIM policy
  # content in plaintext. Use a storage account with RBAC, not access keys.
  backend "azurerm" {}

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

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azurerm" {
  # features {} is required by azurerm even when the configuration creates no
  # azurerm resources. A pure pim_for_groups or entra_role setup still needs it.
  features {}

  # Role bindings use an explicit scope per subscription, so this only needs to
  # be a subscription the identity can authenticate against.
  subscription_id = var.provider_subscription_id
}
