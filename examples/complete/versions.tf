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

  # Pinned to PATCH level, three segments. This repo has no lock files, so these
  # constraints are the only thing pinning provider versions — `~> 5.0` would let
  # the next minor land unchosen on the first init on a clean machine. The full
  # rationale, and what dropping lock files costs, is in ../../versions.tf.
  #
  # `time` is declared even though this example never references it: the
  # access-vending module tree resolves it via time_sleep in pim-for-groups and
  # entra-role-access. An undeclared provider has no upper bound at all.
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14.0"
    }
  }
}
