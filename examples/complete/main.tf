# ==============================================================================
# examples/complete — full setup with all three JIT mechanisms
#
# This is the template for setting up a new environment. Copy this directory,
# change source to a pinned ref, and fill out terraform.tfvars.
#
#   cp -r examples/complete/ ~/my-environment/
#   cd ~/my-environment/
#   cp terraform.tfvars.example terraform.tfvars
#   # edit terraform.tfvars
#   terraform init && terraform plan
#
# ------------------------------------------------------------------------------
# ORDER OF OPERATIONS
#
# 1. bootstrap/ in the vending repo — creates the deploy identity
# 2. ./grant-graph-permissions.sh — Graph permissions
# 3. THIS — creates the groups, RBAC and PIM policies
# 4. access-package repo — gives people access to the groups
#
# Step 3 must come before step 4, and it is stricter than "the groups must exist":
# for pim_for_groups the PIM policy must be written, otherwise the access
# package picker only offers "Member" and not "Eligible Member". The result is
# active membership instead of JIT, without any error.
# ==============================================================================

module "access_vending" {
  # Local path because the example is inside the repo. In your own repo:
  #
  #   source = "github.com/<org>/terraform-azuread-access-vending//modules/access-vending?ref=v1.0.0"
  #
  # Always pin a ref. The module creates groups whose object IDs another repo
  # looks up by name — an unintended upgrade that changes the naming convention
  # breaks that link.
  source = "../../modules/access-vending"

  access_scopes = var.access_scopes

  cloud_prefix                  = var.cloud_prefix
  group_description_template    = var.group_description_template
  set_systemeier_as_group_owner = var.set_systemeier_as_group_owner
  pim_group_propagation_delay   = var.pim_group_propagation_delay
}
