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

output "carrier_group_names" {
  description = <<-EOT
    Eligibility-carrier group name per role key — "{cloud}-{scope}-{role}-eligible".

    THIS is the group an access package attaches to. It is a plain, non-PIM group
    whose only purpose is to be an eligible member of the PIM-managed group, so
    that a package can grant plain Member (which the azuread provider supports)
    instead of EligibleMember (which it cannot set).

    It carries no access of its own and must never appear on the SCIM work list.
  EOT
  value       = local.carrier_group_names
}

output "carrier_group_object_ids" {
  description = "Entra object ID per role key for the eligibility-carrier group."
  value       = module.carrier_groups.group_object_ids
}

output "carrier_eligibility_schedule_ids" {
  description = <<-EOT
    The structural carrier-to-PIM-group eligibility link, per role key.

    Expected to be non-empty for every role. Empty means an access package over
    the carrier would grant carrier membership and no path into the PIM-managed
    group.
  EOT
  value       = { for role_key, mod in module.pim : role_key => mod.carrier_eligibility_schedule_ids }
}

output "access_package_access_type" {
  description = <<-EOT
    access_type that repo 2 should use on the resource role binding. "Member",
    against the CARRIER group — not the PIM-managed group.

    This was "EligibleMember" before contract v2. The provider validates
    azuread_access_package_resource_package_association.access_type client-side
    to Member and Owner only, so EligibleMember could never be applied: those
    roles were excluded and left as a manual portal step, and a user approved for
    the package received no membership at all.

    Granting Member on the carrier is not a downgrade. The carrier holds no
    access; it is an eligible member of the PIM-managed group, so the user still
    has to activate their own membership there and still passes approval, MFA and
    the duration limit.
  EOT
  value       = { for role_key in keys(var.roles) : role_key => "Member" }
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

    ONLY the PIM-managed group appears here, never the "-eligible" carrier. The
    carrier is a pure eligibility carrier: SCIM-provisioning it and binding it to
    a target-cloud role would give every member standing access and bypass PIM
    entirely, with nothing failing. If you are working this list and see a group
    name ending in "-eligible", stop — it does not belong here.
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
