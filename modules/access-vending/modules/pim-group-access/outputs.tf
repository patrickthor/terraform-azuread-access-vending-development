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
    Always "eligible_member" for this module. JIT is in the membership, not in
    the role — opposite of azure-subscription-access, which gives "permanent" or
    "eligible" for the ROLE BINDING.
  EOT
  value       = { for role_key in keys(var.roles) : role_key => "eligible_member" }
}

output "access_package_access_type" {
  description = <<-EOT
    access_type that repo 2 should use on the resource role binding. Always
    "EligibleMember" here: the access package makes the user eligible, and
    activation happens in PIM.
  EOT
  value       = { for role_key in keys(var.roles) : role_key => "EligibleMember" }
}

output "activation_policy_ids" {
  description = "PIM activation policy ID per role key."
  value       = { for role_key, mod in module.pim : role_key => mod.policy_id }
}

output "activation_settings" {
  description = "Effective activation rules per role key, for verification against the test checklist."
  value       = { for role_key, mod in module.pim : role_key => mod.effective_activation_settings }
}

output "eligibility_schedule_ids" {
  description = <<-EOT
    Eligible assignments created by Terraform, per role key and UPN. Normally
    empty — eligibility comes from the access package. Values here mean that
    demo_eligible_user_principal_names is in use.
  EOT
  value       = { for role_key, mod in module.pim : role_key => mod.eligibility_schedule_ids }
}

output "target_cloud_bindings" {
  description = <<-EOT
    The work list for the cloud side. This module does NOT bind the group to
    anything in the target cloud — it must be provisioned there with SCIM and
    bound to the role there. This is what that binding should be, per role key.
  EOT
  value = {
    for role_key, role in var.roles : role_key => {
      group_name  = local.group_names[role_key]
      cloud       = var.cloud_prefix
      scope_id    = var.scope_id
      target_role = role.target_role
    }
  }
}
