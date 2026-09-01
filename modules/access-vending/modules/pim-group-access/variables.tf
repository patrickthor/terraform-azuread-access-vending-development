variable "scope_key" {
  description = <<-EOT
    Short, stable key for the target — AWS account, GCP project or GitHub org.
    Becomes part of the group name {cloud_prefix}-{scope_key}-{role}.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.scope_key))
    error_message = "scope_key must be lowercase letters, digits and hyphens."
  }
}

variable "cloud_prefix" {
  description = <<-EOT
    Prefix for group names: "aws", "gcp", "github" — or "azure" if you
    intentionally want to PIM-manage an Azure group instead of using PIM for
    Azure Resources.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.cloud_prefix))
    error_message = "cloud_prefix must be lowercase letters and digits, no hyphens."
  }
}

variable "scope_id" {
  description = <<-EOT
    Identifier for the target in the relevant cloud — AWS account ID,
    GCP project ID, GitHub org name. For documentation only: no Terraform
    resource in this module binds to it. Authorization happens on the cloud
    side, see README.
  EOT
  type        = string
  default     = ""
}

variable "systemeier" {
  description = <<-EOT
    UPNs of the system owners. At least one.

    ALL become approvers on activation when approval_type is "owner" or "dual".
    azuread_group_role_management_policy allows only ONE approval_stage, so
    multiple system owners are in the same stage and it is sufficient for ONE to
    sign. Broader coverage, not stricter control.

    Only set as group owners if set_systemeier_as_group_owner is true. In M3 the
    consequences of group ownership are greater than in M2 — see that variable.
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
    Roles for this target. Role key becomes part of the group name
    {cloud_prefix}-{scope_key}-{role}, same naming contract as M2.

    One group = one role = one scope. In M3 it is the MEMBERSHIP that is
    just-in-time: the group is PIM-managed, and the access package in repo 2
    grants EligibleMember. There is no permanent_access here — a permanent
    variant would be a plain group without PIM, and then it is not M3.
  EOT

  type = map(object({
    # What the access corresponds to in the target cloud — AWS permission set,
    # GCP role, GitHub team role. PURE DOCUMENTATION. No resource here binds it;
    # the binding happens on the cloud side. Used in the group description and in
    # outputs so it is visible to whoever sets up SCIM.
    target_role = optional(string, "")

    # Applies to the activation of the membership.
    approval_type         = optional(string, "owner")
    max_activation_hours  = optional(number, 8)
    require_mfa           = optional(bool, false)
    require_justification = optional(bool, true)
    require_ticket_info   = optional(bool, false)

    # Max duration for ACTIVE assignments in the group. P15D/P30D/P90D/P180D/P365D,
    # or the sentinel "permanent" which allows permanent active memberships and
    # thereby removes the JIT guarantee for them.
    #
    # The sentinel is a STRING and not null, by design: null here would be
    # replaced by the default below and disappear silently.
    active_assignment_expire_after = optional(string, "P30D")

    # Whether eligible assignments must have an expiration date. false lets the
    # access package own the lifecycle, which is what the POC assumes.
    eligible_assignment_expiration_required = optional(bool, false)

    # ESCAPE HATCH FOR DEMO. In normal operation eligibility comes from the
    # access package in repo 2, not from here. The name is intentionally ugly:
    # if there are values here in production, someone has standing eligibility
    # outside the access package flow.
    demo_eligible_user_principal_names = optional(list(string), [])

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
    error_message = "max_activation_hours must be between 1 and 23 (Entra limit for activation duration)."
  }

  validation {
    condition = alltrue([
      for r in values(var.roles) :
      contains(
        ["P15D", "P30D", "P90D", "P180D", "P365D", "permanent"],
        r.active_assignment_expire_after
      )
    ])
    error_message = "active_assignment_expire_after must be P15D, P30D, P90D, P180D, P365D or \"permanent\". The sentinel is a string and not null — null would be replaced by the default and disappear silently."
  }
}

variable "group_description_template" {
  description = <<-EOT
    Template with placeholders {cloud}, {sub}, {role}, {target_role}, {scope_id}.

    null uses the module's own default. Same placeholder set as
    azure-subscription-access, so a single template in the root works for both
    JIT mechanisms.
  EOT
  type        = string
  default     = null
}

variable "set_systemeier_as_group_owner" {
  description = <<-EOT
    Whether systemeier should be set as owner on the groups. Default false, by
    design.

    A group owner can manage membership directly. In M3 this is worse than in
    M2: a directly added member is an ACTIVE member, not eligible, and thereby
    bypasses both the access package and the entire PIM activation with approval
    and MFA.
  EOT
  type        = bool
  default     = false
}

variable "propagation_delay" {
  description = <<-EOT
    Delay before PIM resources are created, to let newly created groups
    propagate in Graph. Passed through to pim-for-groups.
  EOT
  type        = string
  default     = "30s"
}
