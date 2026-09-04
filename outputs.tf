# ==============================================================================
# Root outputs — re-exports the module's outputs unchanged
#
# The contract with the access-package repo is group_names and
# access_package_access_type, plus approver_group_names for the approver groups.
#
# The descriptions here are intentionally shortened. The full ones are in
# modules/access-vending/outputs.tf, which is the source — repeated in two files
# they would diverge.
# ==============================================================================

output "group_names" {
  description = "Group names per composite key '{scope}--{role}'. This is the contract with"
  value       = module.access_vending.group_names
}

output "group_object_ids" {
  description = "Entra object IDs per composite key."
  value       = module.access_vending.group_object_ids
}

output "jit_mechanism" {
  description = "Which mechanism manages each composite key:"
  value       = module.access_vending.jit_mechanism
}

output "access_package_access_type" {
  description = "access_type repo 2 should use on the resource role binding per composite key."
  value       = module.access_vending.access_package_access_type
}

output "access_model" {
  description = "Access model per composite key:"
  value       = module.access_vending.access_model
}

output "permanent_roles" {
  description = "Composite keys with permanent role assignment. Applies to azure_pim and entra_role"
  value       = module.access_vending.permanent_roles
}

output "jit_roles" {
  description = "Composite keys that require an activation, regardless of mechanism."
  value       = module.access_vending.jit_roles
}

output "activation_settings" {
  description = "Effective activation rules per composite key that has an activation, for verification against tes..."
  value       = module.access_vending.activation_settings
}

output "azure_role_assignment_scopes" {
  description = "Azure RBAC scope per composite key. Only azure_pim roles."
  value       = module.access_vending.azure_role_assignment_scopes
}

output "azure_activation_policy_ids" {
  description = "Activation policy ID per '{scope}|{role}', per scope key. The key is not"
  value       = module.access_vending.azure_activation_policy_ids
}

output "pim_group_policy_ids" {
  description = "PIM for Groups policy ID per composite key. Only pim_for_groups roles."
  value       = module.access_vending.pim_group_policy_ids
}

output "target_cloud_bindings" {
  description = "Work list for the cloud side, per composite key. Only pim_for_groups roles."
  value       = module.access_vending.target_cloud_bindings
}

output "entra_role_template_ids" {
  description = "Template ID per composite key. Only entra_role roles."
  value       = module.access_vending.entra_role_template_ids
}

output "entra_role_object_ids" {
  description = "Object ID for the activated directory role per composite key. Always different from"
  value       = module.access_vending.entra_role_object_ids
}

output "entra_activation_governance_gap" {
  description = "What Terraform does NOT manage for entra_role roles, per composite key."
  value       = module.access_vending.entra_activation_governance_gap
}

output "demo_eligibility_schedules" {
  description = "Eligible assignments Terraform itself has created, per composite key."
  value       = module.access_vending.demo_eligibility_schedules
}

output "access_summary" {
  description = "One line per composite key: group name, mechanism, access model, and what"
  value       = module.access_vending.access_summary
}

output "approver_group_names" {
  description = "Group names per scope key for the approver group."
  value       = module.access_vending.approver_group_names
}

output "approver_group_object_ids" {
  description = "Entra object ID per scope key for the approver group."
  value       = module.access_vending.approver_group_object_ids
}

output "approver_group_is_managed_here" {
  description = "Whether the approver group for the scope is CREATED by this repo (true) or looked"
  value       = module.access_vending.approver_group_is_managed_here
}

output "approvers_by_role" {
  description = "Who approves activation per composite key. Derived from approval_type:"
  value       = module.access_vending.approvers_by_role
}

output "systemeier_by_scope" {
  description = "System owner UPNs per scope key. Repo 2 uses these as named approvers on the access package request gate."
  value       = module.access_vending.systemeier_by_scope
}

# ==============================================================================
# The machine contract
#
# Re-exposed at the root so this repo can be verified standalone. In the real
# two-module setup the customer root wires the module output straight into repo 2
# in memory — there is no terraform_remote_state anywhere:
#
#   module "access_packages" {
#     source  = "github.com/patrickthor/terraform-azuread-access-packages-development//modules/access-packages?ref=v1.0.0"
#     vending = module.access_vending.contract
#   }
#
# One root config, one state, one apply. Apply order is enforced by the
# dependency graph rather than by convention, so a single apply cannot get the
# order wrong.
# ==============================================================================

output "contract" {
  description = "Machine-readable contract for the access-packages repo (repo 2). See modules/access-vending/outputs.tf for the field reference."
  value       = module.access_vending.contract
}

output "catalog_privilege_notes" {
  description = "Scopes whose roles are all entra_role and which share a catalog with other scopes. Advisory only, never a failure."
  value       = module.access_vending.catalog_privilege_notes
}
