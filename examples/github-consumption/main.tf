# ==============================================================================
# Consuming access-vending from your own repo
#
# Copy this directory into your project and copy .github/workflows/deploy.yml
# into your repo's .github/workflows/.
#
# Files:
#   main.tf            this file — module call + forwarded outputs
#   variables.tf       declarations
#   versions.tf        provider blocks + backend
#   terraform.tfvars   YOUR access configuration — commit it, see README
# ==============================================================================

module "access_vending" {
  # ALWAYS PIN A REF.
  #
  # This module creates Entra groups that the access-package repo looks up by
  # NAME. An unintended upgrade that changes the naming convention breaks that
  # link, and the failure surfaces in the *other* repo as "group does not exist"
  # — not here.
  #
  # Terraform requires `source` to be a literal string, so a version bump means
  # editing this line. That is deliberate: it makes the upgrade a reviewable
  # diff rather than a silent variable change.
  source = "github.com/patrickthor/terraform-azuread-access-vending-development//modules/access-vending?ref=v0.1.0"

  access_scopes = var.access_scopes

  cloud_prefix                  = var.cloud_prefix
  group_description_template    = var.group_description_template
  set_systemeier_as_group_owner = var.set_systemeier_as_group_owner
  pim_group_propagation_delay   = var.pim_group_propagation_delay
}

# ==============================================================================
# Outputs — the contract the access-package repo consumes
#
# The module exposes 22 outputs; these are the ones used downstream plus the
# four that are verification tools. See modules/access-vending/outputs.tf for
# the rest.
# ==============================================================================

output "group_names" {
  description = "Group name per composite key '{scope}--{role}'. The access-package repo looks up on this string."
  value       = module.access_vending.group_names
}

output "group_object_ids" {
  description = "Entra object ID per composite key."
  value       = module.access_vending.group_object_ids
}

output "access_package_access_type" {
  description = "Member or EligibleMember per composite key. Set this on the resource role binding in the access-package repo."
  value       = module.access_vending.access_package_access_type
}

output "approver_group_names" {
  description = "Approver group per scope key. Only scopes with a 'dual' role appear here."
  value       = module.access_vending.approver_group_names
}

output "approver_group_object_ids" {
  description = "Entra object ID per approver group, keyed on scope."
  value       = module.access_vending.approver_group_object_ids
}

output "systemeier_by_scope" {
  description = "System owner UPNs per scope. Used as named approvers on the access package request gate."
  value       = module.access_vending.systemeier_by_scope
}

output "target_cloud_bindings" {
  description = "Work list for the cloud side: what SCIM must connect where. pim_for_groups only."
  value       = module.access_vending.target_cloud_bindings
}

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

output "access_summary" {
  description = "One line per role: group name, mechanism, model, access. For reading a plan quickly."
  value       = module.access_vending.access_summary
}

output "approvers_by_role" {
  description = "Who approves activation, per composite key. Check before testing activation."
  value       = module.access_vending.approvers_by_role
}

output "entra_activation_governance_gap" {
  description = "What Terraform does NOT control for entra_role. Empty if you do not use that mechanism."
  value       = module.access_vending.entra_activation_governance_gap
}

output "demo_eligibility_schedules" {
  description = "Should be empty. Values here mean standing eligibility outside the access package flow."
  value       = module.access_vending.demo_eligibility_schedules
}
