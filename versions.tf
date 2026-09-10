# ==============================================================================
# Root module — backend and version requirements
#
# The providers are configured in providers.tf. This file only declares which
# ones are required and where state is stored.
#
# ------------------------------------------------------------------------------
# THIS BLOCK IS THE ONLY THING PINNING PROVIDER VERSIONS
#
# There is no .terraform.lock.hcl. All three repos dropped lock files in favour
# of one source of truth, and that source is the `required_providers` block
# below. Two consequences follow, and both are the point of this comment:
#
#   1. ROOTS PIN TO PATCH LEVEL. Three segments, not two. `~> 5.0` allows 5.5,
#      5.6 and every future minor; `~> 5.4.0` allows only 5.4.x. Without a lock
#      file, `~> 5.0` means the next minor release lands in production the first
#      time someone runs init on a clean machine, with nobody choosing it.
#
#   2. EVERY PROVIDER THE CONFIG RESOLVES MUST BE DECLARED HERE — including ones
#      the root never references itself. `time` is the case in point: the root
#      does not use it, and it was reaching us only through the access-vending
#      module at `>= 0.12` with no upper bound. The lock file was the sole thing
#      pinning it. An undeclared provider is unbounded forever, and `time_sleep`
#      is what lets groups propagate in Graph before PIM resources are written —
#      not a component to leave floating.
#
#      Check with `terraform providers`, which resolves the whole module tree,
#      rather than by reading this file and trusting it.
#
# WHAT DROPPING LOCK FILES COSTS. Recorded here because this is where the
# decision lives, not in a PR description:
#
#   * No checksum verification of provider binaries. The zh:/h1: hashes in the
#     lock file were the only integrity check on the download.
#   * A past deploy cannot be reproduced exactly. Patch releases inside the
#     constraint will differ between runs, so two applies of the same commit can
#     use different provider builds.
#
# CI must NOT pass `-upgrade` to `terraform init`. It re-resolves to the newest
# allowed version on every run — which is how the runner platform moved onto
# azurerm 5.x with nobody choosing it. With no lock file there is nothing for it
# to bypass, so it is inert as well as misleading. If lock files are ever
# reintroduced, use `-lockfile=readonly`: it fails the run when the lock file and
# the constraints disagree, instead of rewriting it inside a container that is
# about to be discarded.
#
# Modules keep `>=`. A reusable module must not become a ceiling for its
# consumers. Only roots pin. See modules/access-vending/versions.tf.
# ------------------------------------------------------------------------------
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

  # Partial backend: the workflow generates backend.hcl from the repository
  # variables STATE_RESOURCE_GROUP / STATE_STORAGE_ACCOUNT_NAME / etc. It does NOT
  # create the storage account — that has to exist first. See backend.hcl.example
  # for the keys if you are running locally.
  #
  # Comment this block out if you ever need to run against local state (a one-off
  # destroy after the state account has been deleted, for example) and re-init
  # with `terraform init -reconfigure`. Plain `init` will try to migrate state to
  # the configured account and fail if it does not exist.
  backend "azurerm" {}

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4.0"
    }
    # Not referenced by the root. Declared because the access-vending module tree
    # resolves it (pim-for-groups and entra-role-access use time_sleep), and with
    # no lock file an undeclared provider has no upper bound at all.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14.0"
    }
  }
}
