terraform {
  required_version = ">= 1.9"

  # No backend here — the example runs on local state. In your own environment,
  # add one:
  #
  #   backend "azurerm" {}
  #
  # and init with -backend-config=backend.hcl. See backend.hcl.example in the
  # repo root.
  #
  # State contains subscription IDs, group object IDs, UPNs and the full PIM
  # policy content in plain text.

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
