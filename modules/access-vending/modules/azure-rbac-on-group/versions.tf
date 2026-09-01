# The ONLY Azure-specific module in this repo.
# Parallel modules for other clouds: aws-permission-set-on-group,
# gcp-iam-on-group, github-team-role-on-group.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}
