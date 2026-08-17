variable "group_object_id" {
  description = "Object ID of the group to be PIM-managed."
  type        = string
}

variable "assignment_type" {
  description = "Which role in the group the policy applies to: 'member' or 'owner'."
  type        = string
  default     = "member"

  validation {
    condition     = contains(["member", "owner"], var.assignment_type)
    error_message = "assignment_type must be 'member' or 'owner'."
  }
}

# ------------------------------------------------------------------------------
# Activation rules
# ------------------------------------------------------------------------------

variable "maximum_activation_duration" {
  description = <<-EOT
    Max duration for an activation, ISO8601. Valid range PT30M–PT23H30M in
    30-minute increments, or PT1D.
  EOT
  type        = string
  default     = "PT8H"

  validation {
    condition     = can(regex("^PT([0-9]|1[0-9]|2[0-3])H(30M)?$|^PT30M$|^PT1D$", var.maximum_activation_duration))
    error_message = "maximum_activation_duration must be in the form PT8H, PT8H30M, PT30M or PT1D."
  }
}

variable "require_approval" {
  description = "Requires approval for activation. Requires at least one primary_approver."
  type        = bool
  default     = false
}

variable "primary_approvers" {
  description = <<-EOT
    Approvers for activation. Entra/PIM for Groups supports only **one**
    approval stage — all approvers here are in the same stage, and it is
    sufficient for one of them to sign. See B3 in the module README.

    `type` is "singleUser" or "groupMembers".
  EOT
  type = list(object({
    object_id = string
    type      = string
  }))
  default = []

  validation {
    condition = alltrue([
      for a in var.primary_approvers : contains(["singleUser", "groupMembers"], a.type)
    ])
    error_message = "primary_approvers[*].type must be 'singleUser' or 'groupMembers'."
  }
}

variable "require_multifactor_authentication" {
  description = "Requires MFA on activation."
  type        = bool
  default     = false
}

variable "require_justification" {
  description = "Requires justification on activation and on new active assignments."
  type        = bool
  default     = true
}

variable "require_ticket_info" {
  description = "Requires ticket number/system on activation."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Assignment rules
# ------------------------------------------------------------------------------

variable "eligible_assignment_expiration_required" {
  description = <<-EOT
    Whether eligible assignments must have an expiration date. false allows
    permanent eligibility, which is what the POC uses (expiry is controlled by
    the access package).
  EOT
  type        = bool
  default     = false
}

variable "active_assignment_expire_after" {
  description = <<-EOT
    Max duration for ACTIVE assignments. P15D, P30D, P90D, P180D or P365D.

    The sentinel "permanent" allows permanent active assignments and removes
    the JIT guarantee for them. It is a STRING and not null, by design:
    `optional(string, "P30D")` and a variable's `default` both replace
    explicit null with the default value, so a null-based sentinel would
    disappear silently through the module layers.

    The module translates the sentinel itself, and simultaneously sets
    expiration_required. Both are needed: expire_after is Optional+Computed,
    so null there does not remove any limit — it is expiration_required that
    determines whether the limit applies.
  EOT
  type        = string
  default     = "P30D"

  validation {
    condition = contains(
      ["P15D", "P30D", "P90D", "P180D", "P365D", "permanent"],
      var.active_assignment_expire_after
    )
    error_message = "active_assignment_expire_after must be P15D, P30D, P90D, P180D, P365D or \"permanent\"."
  }
}

# ------------------------------------------------------------------------------
# Eligible members
# ------------------------------------------------------------------------------

variable "eligible_member_user_principal_names" {
  description = <<-EOT
    Users who should be eligible for activation, as UPN. The module looks them
    up with data "azuread_user".
  EOT
  type        = list(string)
  default     = []
}

variable "eligible_permanent" {
  description = "Whether the eligible assignments should be permanent (no expiry)."
  type        = bool
  default     = true
}

variable "eligible_duration" {
  description = <<-EOT
    Duration of the eligible assignment when eligible_permanent = false, ISO8601
    (e.g. P365D).
  EOT
  type        = string
  default     = null
}

variable "eligible_justification" {
  description = "Justification stored on the eligible assignment."
  type        = string
  default     = "Assigned by Terraform (POC vending)."
}

# ------------------------------------------------------------------------------
# Propagation
# ------------------------------------------------------------------------------

variable "propagation_delay" {
  description = <<-EOT
    Delay before PIM resources are created, to let newly created groups
    propagate in Graph. Set to "0s" if the group is known to be old.
  EOT
  type        = string
  default     = "30s"
}
