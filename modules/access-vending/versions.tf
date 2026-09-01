# ==============================================================================
# Consumable module — access vending
#
# NO provider blocks here. The providers are owned by the caller, which is the
# requirement for the module to be usable with count, for_each and depends_on.
# See examples/complete/providers.tf for a working setup.
#
# required_version is >= 1.9 because the validations use cross-variable
# references: the validation of var.access_scopes references var.cloud_prefix,
# and the two composite modules reference var.approver_group_object_id in the
# validation of var.roles. This is a 1.9 feature. On 1.5-1.8 the configuration
# fails with "Invalid reference in variable validation" before anything else
# happens.
# ==============================================================================

terraform {
  required_version = ">= 1.9"

  # ----------------------------------------------------------------------------
  # Provider constraints use >= , not ~> , ON PURPOSE.
  #
  # This is a module other repos consume. A `~>` here becomes a CEILING the
  # caller cannot raise: if azuread 4.0 ships, every consumer is blocked until
  # this module cuts a release, because Terraform requires all constraints in
  # the graph to be satisfiable simultaneously.
  #
  # The convention is `>=` in reusable modules and `~>` in root configurations,
  # where a lockfile plus a single owner make pinning safe. This repo's own root,
  # examples/ and bootstrap/ therefore keep `~>`.
  #
  # The floors are real, not arbitrary:
  #   azuread >= 3.7   azuread_group_role_management_policy and the
  #                    privileged_access_group_* resources
  #   azurerm >= 4.0   azurerm_pim_eligible_role_assignment
  #   time    >= 0.12  time_sleep triggers behaviour relied on for propagation
  # ----------------------------------------------------------------------------
  required_providers {
    # Groups, PIM for Groups and Entra directory roles.
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }

    # Only the azure_pim track: Azure RBAC and PIM for Azure Resources. Declared
    # here because modules/azure-rbac-on-group uses it. A configuration without
    # azure_pim roles creates no azurerm resources, but the caller must still
    # configure the provider — azurerm requires a provider block because of
    # features {}.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }

    # Wait time for Graph propagation in the pim_for_groups and entra_role track.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
  }
}
