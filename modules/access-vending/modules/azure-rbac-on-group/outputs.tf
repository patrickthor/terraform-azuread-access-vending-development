output "scopes" {
  description = "Scope per binding key."
  value       = { for k, a in var.assignments : k => a.scope }
}

output "access_model" {
  description = <<-EOT
    Access model per binding key: "permanent" or "eligible". Useful for
    verifying that permanent_access was interpreted as expected.
  EOT
  value = {
    for k, a in var.assignments :
    k => a.permanent_access ? "permanent" : "eligible"
  }
}

output "role_definition_ids" {
  description = "Looked-up role_definition_id per binding key."
  value = {
    for k, a in var.assignments :
    k => data.azurerm_role_definition.this["${a.scope}|${a.role_definition_name}"].id
  }
}

output "permanent_role_assignment_ids" {
  description = "Resource ID per permanent role binding."
  value       = { for k, r in azurerm_role_assignment.permanent : k => r.id }
}

output "eligible_role_assignment_ids" {
  description = "Resource ID per eligible role binding."
  value       = { for k, r in azurerm_pim_eligible_role_assignment.this : k => r.id }
}

output "activation_policy_ids" {
  description = <<-EOT
    Policy ID per "{scope}|{role}". The key is not the binding key, because the
    policy is keyed on (scope, role) in Azure and not per group.
  EOT
  value       = { for k, r in azurerm_role_management_policy.activation : k => r.id }
}

output "effective_activation_settings" {
  description = "Effective activation rules per eligible binding key, for verification."
  value = {
    for k, a in var.assignments : k => {
      maximum_duration      = "PT${a.max_activation_hours}H"
      require_approval      = a.require_approval
      require_mfa           = a.require_mfa
      require_justification = a.require_justification
      require_ticket_info   = a.require_ticket_info
      approver_count        = length(a.approvers)
    } if !a.permanent_access
  }
}
