output "policy_id" {
  description = "ID of the PIM activation policy."
  value       = azuread_group_role_management_policy.this.id
}

output "eligibility_schedule_ids" {
  description = "ID per eligible assignment, keyed on UPN."
  value = {
    for upn, sched in azuread_privileged_access_group_eligibility_schedule.this :
    upn => sched.id
  }
}

output "eligible_principal_object_ids" {
  description = "Object ID per eligible user, keyed on UPN."
  value       = { for upn, u in data.azuread_user.eligible : upn => u.object_id }
}

output "carrier_eligibility_schedule_ids" {
  description = <<-EOT
    ID per eligibility-carrier assignment, keyed on the static carrier label.

    Unlike eligibility_schedule_ids this is expected to be NON-empty in normal
    operation — it is the structural link that lets an access package over the
    carrier group grant a path into this PIM-managed group. Empty here means
    packages built on the carrier grant membership in the carrier and nothing
    further.
  EOT
  value = {
    for label, sched in azuread_privileged_access_group_eligibility_schedule.carrier :
    label => sched.id
  }
}

output "effective_activation_settings" {
  description = "Summary of the activation rules that were set, for verification."
  value = {
    maximum_duration      = var.maximum_activation_duration
    require_approval      = var.require_approval
    require_mfa           = var.require_multifactor_authentication
    require_justification = var.require_justification
    approver_count        = length(var.primary_approvers)
    approval_stages       = var.require_approval ? 1 : 0
  }
}
