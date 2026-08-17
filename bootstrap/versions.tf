terraform {
  required_version = ">= 1.9"

  # LOCAL state on purpose. The bootstrap creates the identity that will have
  # access to remote state; it cannot itself reside there.
  #
  # Consequence: terraform.tfstate on disk here is the only source of what the
  # bootstrap has created. Keep it, or be prepared to import.

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}
