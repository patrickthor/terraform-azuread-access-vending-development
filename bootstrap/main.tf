# ==============================================================================
# Bootstrap — one-time setup of the deploy identity
#
# Creates a user-assigned managed identity with a federated credential for
# GitHub Actions OIDC. Uses LOCAL state intentionally: this is the chicken that
# lays the egg, and it cannot reside in a state it gives access to itself.
#
# Run once per environment by an admin with `az login`:
#
#   cp terraform.tfvars.example terraform.tfvars
#   terraform init
#   terraform apply -var-file=terraform.tfvars
#
# Afterwards, Graph permissions must be granted. This is NOT automated,
# intentionally — it requires Privileged Role Administrator or Global
# Administrator, and an admin should see what is being granted:
#
#   ./grant-graph-permissions.sh
#
# ------------------------------------------------------------------------------
# WHY MANAGED IDENTITY AND NOT APP REGISTRATION
#
# A managed identity has no client secret that can leak, be copied or expire.
# Federated credentials mean that GitHub Actions exchanges a short-lived OIDC
# token for an Azure token on each run. Nothing secret is stored in GitHub.
#
# A consequence worth knowing: the identity cannot be PIM-protected. Eligible
# assignments cannot be created for service principals, because they cannot
# activate. The deploy identity therefore has standing privileges, and they are
# extensive — see grant-graph-permissions.sh. Treat it as tenant admin.
# ==============================================================================

module "bootstrap" {
  source = "github.com/patrickthor/terraform-azurerm-workload-identity?ref=main"

  identity_name         = var.identity_name
  resource_group_name   = var.resource_group_name
  location              = var.location
  create_resource_group = var.create_resource_group

  github_org    = var.github_org
  github_repo   = var.github_repo
  github_branch = var.github_branch

  state_storage_account_id = var.state_storage_account_id
}
