# ==============================================================================
# Outputs — the contract with the access-package repo
#
# The module has 21 outputs. Here the ones that are actually used downstream are
# exposed, plus the three that are verification tools. See
# modules/access-vending/outputs.tf for the rest.
# ==============================================================================

# ------------------------------------------------------------------------------
# Contract with repo 2
# ------------------------------------------------------------------------------

output "group_names" {
  description = "Group name per composite key. Repo 2 looks up on this string."
  value       = module.access_vending.group_names
}

output "access_package_access_type" {
  description = "Member or EligibleMember per composite key. Repo 2 sets this on the resource role binding."
  value       = module.access_vending.access_package_access_type
}

output "approver_group_names" {
  description = "Approver group per scope key. Repo 2 manages membership in these."
  value       = module.access_vending.approver_group_names
}

output "target_cloud_bindings" {
  description = "The work list for the cloud side: what SCIM must connect where. Only pim_for_groups."
  value       = module.access_vending.target_cloud_bindings
}

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------

output "access_summary" {
  description = "One line per role: group name, mechanism, model, access. For reading the plan quickly."
  value       = module.access_vending.access_summary
}

output "approvers_by_role" {
  description = "Who approves what. Check this before testing activation."
  value       = module.access_vending.approvers_by_role
}

output "entra_activation_governance_gap" {
  description = "What Terraform does NOT control for entra_role. Empty if you are not using M4."
  value       = module.access_vending.entra_activation_governance_gap
}

output "demo_eligibility_schedules" {
  description = "Should be empty. Values here mean standing eligibility outside the access package flow."
  value       = module.access_vending.demo_eligibility_schedules
}
