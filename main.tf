# ==============================================================================
# Root module — thin passthrough that calls modules/access-vending
#
# This file is used by this repo's own deploy workflow. External consumers should
# reference the module directly:
#
#   module "access_vending" {
#     source = "github.com/<org>/terraform-azuread-access-vending//modules/access-vending?ref=v1.0.0"
#     ...
#   }
#
# See examples/complete/ for a full setup with providers and tfvars.
#
# The reason the root exists at all: azurerm requires a provider block because
# of features {}, and a reusable module should not have provider blocks — that
# would prevent the caller from using count, for_each or depends_on on it. The
# root therefore owns the providers and the backend; the module owns the logic.
# ==============================================================================

module "access_vending" {
  source = "./modules/access-vending"

  access_scopes = var.access_scopes

  cloud_prefix                  = var.cloud_prefix
  default_catalog               = var.default_catalog
  group_description_template    = var.group_description_template
  set_systemeier_as_group_owner = var.set_systemeier_as_group_owner
  pim_group_propagation_delay   = var.pim_group_propagation_delay
}
