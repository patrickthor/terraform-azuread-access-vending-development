# ==============================================================================
# Providers — the caller's responsibility
#
# modules/access-vending intentionally has no provider blocks. That is why this
# file exists, and that is why the module can be used with count, for_each and
# depends_on.
#
# azurerm requires features {} even if the configuration does not create any
# azurerm resources. A pure pim_for_groups or entra_role configuration must
# therefore still configure it.
# ==============================================================================

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azurerm" {
  features {}
  subscription_id = var.provider_subscription_id
}
