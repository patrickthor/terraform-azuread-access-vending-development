# Composite for M3 — PIM for Groups.
#
# Only azuread + time. NO azurerm, by design: this path handles AWS, GCP, and
# GitHub, where Azure Resource Manager is not involved at all.
# Provider isolation is an acceptance criterion — see the verification in README.
#
# `time` comes from pim-for-groups, which waits for Graph propagation before the
# PIM endpoints are hit on a newly created group.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12"
    }
  }
}
