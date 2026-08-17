variable "subscription_key" {
  description = "Short, stable key for the subscription. Becomes part of the group name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.subscription_key))
    error_message = "subscription_key must be lowercase letters, digits and hyphens."
  }
}

variable "subscription_id" {
  description = "Azure subscription ID (GUID)."
  type        = string
}

variable "systemeier" {
  description = <<-EOT
    UPNs of the system owners. At least one.

    ALL become approvers on role activation when approval_type is "owner" or
    "dual". Note what this means: azurerm_role_management_policy allows only ONE
    approval_stage, so multiple system owners are in the same stage and it is
    sufficient for ONE to sign. Multiple system owners provide broader coverage
    — e.g. so that vacation does not block activation — not stricter control.

    Only set as group owners if set_systemeier_as_group_owner is true — which
    it is not by default. See that variable for why.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.systemeier) > 0
    error_message = "systemeier must have at least one UPN."
  }

  validation {
    condition     = length(distinct(var.systemeier)) == length(var.systemeier)
    error_message = "systemeier cannot contain duplicates — primary_approver is a set, so duplicates disappear silently."
  }
}

variable "approver_group_object_id" {
  description = <<-EOT
    Object ID of the approver group for the scope. Used as primary_approver
    when approval_type is "dual", together with systemeier.

    Created in the root module, one per scope, because a scope can have roles in
    multiple JIT mechanisms — if it were here, a scope with both azure_pim and
    pim_for_groups would get two groups with the same name.

    null is valid, but only when no role uses "dual".
  EOT
  type        = string
  default     = null
}

variable "roles" {
  description = <<-EOT
    Roles for this subscription. Role key becomes part of the group name
    {cloud_prefix}-{sub}-{role}. No module code special-cases role names.

    One group carries exactly one role at subscription scope. Different
    access levels are given as different roles, i.e. different groups.
  EOT

  type = map(object({
    azure_role = string

    # false (default) = eligible assignment, the user activates the role (JIT).
    # true            = permanent assignment, access as long as they are a member.
    permanent_access = optional(bool, false)

    # Applies to the activation. No effect when permanent_access = true.
    approval_type         = optional(string, "owner")
    max_activation_hours  = optional(number, 8)
    require_mfa           = optional(bool, false)
    require_justification = optional(bool, true)
    require_ticket_info   = optional(bool, false)

    # How long the group is eligible. null = permanent eligibility.
    eligible_duration_days = optional(number)

    # Force-replace on azuread_group. Set true only if the group should also
    # carry Entra directory roles. See risk R3.
    assignable_to_role = optional(bool, false)
  }))

  validation {
    condition = alltrue([
      for r in values(var.roles) :
      contains(["self", "owner", "dual"], r.approval_type)
    ])
    error_message = "approval_type must be one of: self, owner, dual."
  }

  validation {
    condition = alltrue([
      for r in values(var.roles) :
      r.approval_type == "dual" ? var.approver_group_object_id != null : true
    ])
    error_message = "approver_group_object_id must be set when at least one role has approval_type 'dual'. Without it the role would require group approval but have no approver group."
  }

  validation {
    condition = alltrue([
      for r in values(var.roles) :
      r.max_activation_hours >= 1 && r.max_activation_hours <= 23
    ])
    error_message = "max_activation_hours must be between 1 and 23."
  }

  validation {
    # azurerm_role_management_policy is keyed on (scope, role). Two eligible
    # roles with the same azure_role on the same subscription would collide.
    condition = length(distinct([
      for r in values(var.roles) : r.azure_role if !r.permanent_access
      ])) == length([
      for r in values(var.roles) : r.azure_role if !r.permanent_access
    ])
    error_message = "Two eligible roles cannot have the same azure_role on the same subscription — the activation policy is keyed on (scope, role) and they would collide."
  }
}

variable "cloud_prefix" {
  description = "Prefix for group names. \"azure\" gives azure-{sub}-{role}."
  type        = string
  default     = "azure"
}

variable "group_description_template" {
  description = <<-EOT
    Template with placeholders {cloud}, {sub}, {role}, {target_role}, {scope_id}.
    {target_role} is the Azure RBAC role here; {scope_id} is the subscription ID.

    null uses the module's own default. Same placeholder set as pim-group-access,
    so a single template in the root works for both JIT mechanisms.
  EOT
  type        = string
  default     = null
}

variable "set_systemeier_as_group_owner" {
  description = <<-EOT
    Whether systemeier should be set as owner on the groups. Default false, by
    design.

    A group owner can manage membership directly and thereby bypass the access
    package entirely. Combined with membership being managed outside Terraform
    (ignore_changes), such a bypass would never be flagged in a plan.

    systemeier does not need to be an owner to be an approver — those are two
    independent mechanisms in this module.
  EOT
  type        = bool
  default     = false
}
