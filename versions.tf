# ==============================================================================
# Root module — backend and version requirements
#
# The providers are configured in providers.tf. This file only declares which
# ones are required and where state is stored.
#
# `time` is not declared here because the root does not use it directly. It is
# required by pim-for-groups and entra-role-access, which declare it themselves.
# Note that the root does not use azurerm directly either — it is here solely
# because providers.tf configures it on the module's behalf.
#
# required_version >= 1.9: the module's validations use cross-variable
# references, which is a 1.9 feature. On 1.5-1.8 the configuration fails with
# "Invalid reference in variable validation" before anything else happens.
# ==============================================================================

terraform {
  required_version = ">= 1.9"

  # Partial backend — provide the rest with:
  #   terraform init -backend-config=backend.hcl
  # See backend.hcl.example for the keys.
  #
  # State contains subscription IDs, group object IDs, UPNs and full PIM policy
  # content in plaintext. Local state is fine for a demo, but not for anything
  # more than one person will run.

  # Uncomment the line below to use remote state
  #backend "azurerm" {}

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
