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
    Access model per role key:

      "permanent"  the directory role is permanently bound to the group
      "eligible"   the group is eligible, members activate in PIM

    Same meaning as in azure-subscription-access: JIT is in the ROLE.
  EOT
  value = {
    for role_key, role in var.roles :
    role_key => role.permanent_access ? "permanent" : "eligible"
  }
}

output "access_package_access_type" {
  description = <<-EOT
    access_type that repo 2 should use. Always "Member": membership in the
    group is active, and it is the directory ROLE that may need to be activated
    in PIM.
  EOT
  value       = { for role_key in keys(var.roles) : role_key => "Member" }
}

output "directory_role_template_ids" {
  description = <<-EOT
    Looked-up template ID per role key. This is the roleDefinitionId that Graph
    uses, not the object ID of the activated directoryRole.
  EOT
  value = {
    for role_key, role in var.roles :
    role_key => azuread_directory_role.this[role.entra_role].template_id
  }
}

output "directory_role_object_ids" {
  description = <<-EOT
    Object ID per role key for the ACTIVATED directory role. Always different
    from the template ID. Included because confusing the two is a classic source
    of 400 from Graph.
  EOT
  value = {
    for role_key, role in var.roles :
    role_key => azuread_directory_role.this[role.entra_role].object_id
  }
}

output "directory_scope_id" {
  description = "The scope the role bindings are set on. \"/\" means the entire tenant."
  value       = var.directory_scope_id
}

output "permanent_role_assignment_ids" {
  description = "Resource ID per permanent directory role binding."
  value       = { for k, r in azuread_directory_role_assignment.permanent : k => r.id }
}

output "eligibility_request_ids" {
  description = "Resource ID per eligible directory role binding."
  value       = { for k, r in azuread_directory_role_eligibility_schedule_request.this : k => r.id }
}

output "activation_governance_gap" {
  description = <<-EOT
    The activation rules Terraform CANNOT set for these roles.

    This output exists so the gap is visible in plan and output, not just in a
    README. The value is intentionally static: it describes a limitation in the
    provider, not something read from the tenant.
  EOT
  value = {
    for role_key, role in var.roles :
    role_key => role.permanent_access ? "Not relevant — permanent binding, no activation." : "MFA, approval, max duration, and justification requirements must be set in the PIM portal for directory role '${role.entra_role}'. The azuread provider has no policy resource for directory roles."
  }
}
