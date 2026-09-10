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

  # --- azurerm 5.x behaviour this block deliberately relies on ----------------
  #
  # resource_provider_registrations defaults to "none" from 5.0, where 4.x
  # defaulted to "legacy" and walked ~60 resource provider registrations at
  # startup. Left at the default on purpose: it removes that startup delay and
  # the permission errors it caused for identities with restricted subscription
  # access. These modules only touch Microsoft.Authorization, which is always
  # registered, so there is nothing to register. Use
  # resource_providers_to_register if that ever changes — do NOT set
  # resource_provider_registrations = "legacy" just to silence something.
  #
  # skip_provider_registration was REMOVED in 5.0. It is not used anywhere in
  # this repo, so there is nothing to migrate.
  #
  # enhanced_validation moved inside features {} in 5.0 and now defaults to OFF,
  # so an invalid location surfaces at apply instead of at plan. No impact on THIS
  # root: the only azurerm resources it creates are role assignments, PIM
  # eligibility and role management policies, all scoped by resource ID, and none
  # of them takes a location.
  #
  # That is a per-root statement, not a repo-wide one. bootstrap/ is a separate
  # root, it DOES set a location (var.location, passed to the workload-identity
  # module, which creates the resource group), and it turns the validation back on
  # for exactly that reason. See bootstrap/versions.tf.
  #
  # If a location-bearing resource is ever added here, the block is:
  #
  #   features {
  #     enhanced_validation {
  #       locations = true
  #     }
  #   }
  #
  # Note that enhanced_validation is a SUB-BLOCK of features, not an attribute of
  # it. Writing `features { enhanced_validation = true }` fails with an unsupported
  # argument error.
}
