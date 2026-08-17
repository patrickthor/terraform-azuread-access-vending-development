output "group_names" {
  description = <<-EOT
    Group name per role key. The contract with the access-package repo — the
    same string is used as display_name in data "azuread_group" there.
  EOT
  value       = local.group_names
}

output "group_object_ids" {
  description = "Entra object ID per role key."
  value       = module.groups.group_object_ids
}

output "access_model" {
  description = <<-EOT
    Access model per role key: "permanent" or "eligible".

    Repo 2 needs this to choose access_type on the resource role binding:
    "permanent" and "eligible" both give access_type = "Member" on Azure, since
    JIT is in the role and not in the membership.
  EOT
  value       = module.rbac.access_model
}

output "role_assignment_scopes" {
  description = "Azure RBAC scope per role key."
  value       = module.rbac.scopes
}

output "permanent_role_assignment_ids" {
  description = "Resource ID per permanent role binding."
  value       = module.rbac.permanent_role_assignment_ids
}

output "eligible_role_assignment_ids" {
  description = "Resource ID per eligible role binding."
  value       = module.rbac.eligible_role_assignment_ids
}

output "activation_policy_ids" {
  description = <<-EOT
    Activation policy ID per "{scope}|{role}". The key is not the role key,
    because the policy is keyed on (scope, role) in Azure and not per group.
  EOT
  value       = module.rbac.activation_policy_ids
}

output "activation_settings" {
  description = "Effective activation rules per eligible role key, for verification."
  value       = module.rbac.effective_activation_settings
}

output "subscription_scope" {
  description = "The scope string used for the role bindings."
  value       = local.subscription_scope
}
