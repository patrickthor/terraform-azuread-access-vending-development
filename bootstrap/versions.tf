terraform {
  required_version = ">= 1.9"

  # LOCAL state on purpose. The bootstrap creates the identity that will have
  # access to remote state; it cannot itself reside there.
  #
  # Consequence: terraform.tfstate on disk here is the only source of what the
  # bootstrap has created. Keep it, or be prepared to import.

  # Pinned to PATCH level, three segments. There is no lock file in this repo, so
  # this constraint is the only thing pinning the provider — `~> 5.0` would let
  # the next minor land here unchosen. See ../versions.tf for the full rationale
  # and what dropping lock files costs.
  #
  # azurerm is the only provider this root resolves; the workload-identity module
  # it calls needs nothing else. Verify with `terraform providers` rather than by
  # reading this list, and add anything new here if that output changes.
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4.0"
    }
  }
}

provider "azurerm" {
  features {
    # azurerm 5.0 moved enhanced_validation into features {} and turned it OFF by
    # default, so an invalid location is no longer caught at plan time — it fails
    # during apply instead.
    #
    # That matters HERE specifically, unlike the repo root: this is the only root
    # that sets a location (var.location, passed to the workload-identity module,
    # which creates the resource group). A typo like "norwayeats" would previously
    # have failed the plan; on 5.x with the default it reaches apply, and the
    # bootstrap keeps its state locally, so a half-created bootstrap is the most
    # awkward thing in this repo to recover from.
    #
    # Turned back on rather than validating var.location against a hand-written
    # region list, which would go stale every time Azure adds a region.
    enhanced_validation {
      locations = true
    }
  }
}
