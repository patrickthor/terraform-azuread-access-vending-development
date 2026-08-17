# Cloud-agnostic module: only azuread. No azurerm here — it is an acceptance
# criterion that this module can be used without azurerm installed.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
  }
}
