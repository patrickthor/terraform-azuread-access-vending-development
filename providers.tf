# ==============================================================================
# Provider configuration — belongs to the ROOT MODULE, not the module
#
# modules/access-vending intentionally has no provider blocks. A reusable module
# that configures providers itself cannot be used with count, for_each or
# depends_on, and resources cannot be cleanly removed because the provider
# configuration disappears along with the last resources.
#
# If you call the module from your own repo, YOU own this file. See
# examples/complete/providers.tf.
# ==============================================================================

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azurerm" {
  # features {} is required by azurerm and is the reason this repo cannot be a
  # pure module without a root around it.
  features {}

  # Role assignments are set with explicit scope per subscription, so this only
  # needs to be a valid context the provider can authenticate against.
  subscription_id = var.provider_subscription_id
}
