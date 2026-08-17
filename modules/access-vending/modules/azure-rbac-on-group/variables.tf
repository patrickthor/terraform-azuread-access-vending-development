variable "assignments" {
  description = <<-EOT
    Role assignments to create, keyed on a stable identifier.

    `permanent_access` controls which resource type is used:

      false (default)  eligible assignment — the user must activate the role.
                       Creates azurerm_pim_eligible_role_assignment plus
                       azurerm_role_management_policy with the activation rules.

      true             permanent assignment — access as long as the principal is
                       a member of the group. Creates azurerm_role_assignment.
                       The time limit then comes from the expiry on the access
                       package assignment, not from here.

    The activation fields (max_activation_hours, require_approval, approvers,
    require_mfa, require_justification) have no effect when
    permanent_access = true.
  EOT

  type = map(object({
    principal_object_id = string

    # Azure RBAC role name, e.g. "Reader". Free string — no hard-coding.
    role_definition_name = string

    scope       = string
    description = optional(string)

    permanent_access = optional(bool, false)

    # ---- Only applies when permanent_access = false ----

    max_activation_hours  = optional(number, 8)
    require_approval      = optional(bool, true)
    require_mfa           = optional(bool, false)
    require_justification = optional(bool, true)
    require_ticket_info   = optional(bool, false)

    # Approvers for the activation. type must be "User" or "Group" —
    # azurerm uses different values than azuread, which has singleUser/groupMembers.
    approvers = optional(list(object({
      object_id = string
      type      = string
    })), [])

    # How long the eligibility lasts. null = permanent eligibility.
    # Azure otherwise often caps this at 365 days.
    eligible_duration_days = optional(number)
  }))

  default = {}

  validation {
    condition = alltrue([
      for a in values(var.assignments) :
      a.max_activation_hours >= 1 && a.max_activation_hours <= 23
    ])
    error_message = "max_activation_hours must be between 1 and 23."
  }

  validation {
    condition = alltrue(flatten([
      for a in values(var.assignments) : [
        for ap in a.approvers : contains(["User", "Group"], ap.type)
      ]
    ]))
    error_message = "approvers[*].type must be \"User\" or \"Group\" (azurerm values, not azuread's singleUser/groupMembers)."
  }

  validation {
    condition = alltrue([
      for a in values(var.assignments) :
      a.permanent_access || !a.require_approval || length(a.approvers) > 0
    ])
    error_message = "Eligible assignments with require_approval = true must have at least one approver in approvers."
  }

  validation {
    # expire_after on eligible_assignment_rules only accepts a fixed set of durations.
    # Without this validation a value like 45 would only fail at apply, after the
    # policy is already partially modified.
    condition = alltrue([
      for a in values(var.assignments) :
      a.eligible_duration_days == null || contains([15, 30, 90, 180, 365], coalesce(a.eligible_duration_days, 30))
    ])
    error_message = "eligible_duration_days must be 15, 30, 90, 180 or 365 — Azure only accepts P15D/P30D/P90D/P180D/P365D as eligible assignment expiry. null gives permanent eligibility."
  }

  validation {
    # azurerm_role_management_policy is keyed on (scope, role) — not per
    # group. Two eligible assignments with the same role on the same scope would
    # attempt to manage the same policy object.
    condition = length(distinct([
      for a in values(var.assignments) :
      "${a.scope}|${a.role_definition_name}" if !a.permanent_access
      ])) == length([
      for a in values(var.assignments) :
      "${a.scope}|${a.role_definition_name}" if !a.permanent_access
    ])
    error_message = "Two eligible assignments cannot have the same role_definition_name on the same scope — azurerm_role_management_policy is keyed on (scope, role) and they would collide."
  }
}
