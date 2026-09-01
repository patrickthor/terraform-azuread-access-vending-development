variable "scope_key" {
  description = <<-EOT
    Short, stable key for the scope. Becomes part of the group name
    {cloud_prefix}-{scope_key}-{role}.

    Directory roles are tenant-global, so there is no natural scope to name.
    "tenant" is a reasonable value for the entire tenant. If the role is scoped
    to an administrative unit, use its name.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.scope_key))
    error_message = "scope_key must be lowercase letters, digits and hyphens."
  }
}

variable "cloud_prefix" {
  description = <<-EOT
    Prefix for group names. Should be "entra" for this module — the root module
    validates that. Exists as a variable only to keep the interface consistent
    with the other two composite modules.
  EOT
  type        = string
  default     = "entra"
}

variable "directory_scope_id" {
  description = <<-EOT
    Graph directory_scope_id for the role assignment.

      "/"                              the entire tenant
      "/administrativeUnits/<guid>"    scoped to a single administrative unit

    Note that not all directory roles can be scoped to an administrative unit.
    Graph rejects the combination at apply if the role does not support it.
  EOT
  type        = string
  default     = "/"

  validation {
    condition     = var.directory_scope_id == "/" || can(regex("^/administrativeUnits/[0-9a-fA-F-]{36}$", var.directory_scope_id))
    error_message = "directory_scope_id must be \"/\" or \"/administrativeUnits/<guid>\"."
  }
}

variable "systemeier" {
  description = <<-EOT
    UPNs of the system owners. At least one.

    Unlike M2 and M3 they are NOT used as approvers here: Terraform cannot set
    approval rules for directory roles. They are only used if
    set_systemeier_as_group_owner is true.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.systemeier) > 0
    error_message = "systemeier must have at least one UPN."
  }

  validation {
    condition     = length(distinct(var.systemeier)) == length(var.systemeier)
    error_message = "systemeier cannot contain duplicates."
  }
}

variable "roles" {
  description = <<-EOT
    Directory roles for this scope. Role key becomes part of the group name
    {cloud_prefix}-{scope_key}-{role}, same naming contract as M2 and M3.

    One group = one directory role. The groups are always set as role-assignable
    — that is a requirement from Entra for a group to carry a directory role,
    and therefore not configurable here.
  EOT

  type = map(object({
    # Display name of the directory role, e.g. "Groups Administrator".
    # Looked up against directoryRoleTemplates. The role is activated in the
    # tenant if it is not already active.
    entra_role = string

    # false (default) = eligible assignment, the user activates the role in PIM.
    # true            = permanent assignment, the role applies as long as the
    #                   membership lasts.
    permanent_access = optional(bool, false)

    # Justification that accompanies the eligible request. Graph requires a
    # non-empty field, hence the default.
    eligible_justification = optional(string, "Created by access vending (Terraform)")
  }))

  validation {
    condition = alltrue([
      for r in values(var.roles) : length(trimspace(r.entra_role)) > 0
    ])
    error_message = "entra_role cannot be empty."
  }

  validation {
    condition = alltrue([
      for r in values(var.roles) : length(trimspace(r.eligible_justification)) > 0
    ])
    error_message = "eligible_justification cannot be empty — Graph rejects the request."
  }
}

variable "group_description_template" {
  description = <<-EOT
    Template with placeholders {cloud}, {sub}, {role}, {target_role}, {scope_id}.
    {target_role} is the directory role here.

    null uses the module's own default. Same placeholder set as the other two
    composite modules, so a single template in the root works for all three.
  EOT
  type        = string
  default     = null
}

variable "set_systemeier_as_group_owner" {
  description = <<-EOT
    Whether systemeier should be set as owner on the groups. Default false, by
    design.

    The consequences are more severe here than in M2 and M3: an owner of a
    role-assignable group can add members directly, and they then receive a
    directory role without going through the access package. For eligible
    assignments they still need to activate in PIM, but for permanent assignments
    access is immediate.
  EOT
  type        = bool
  default     = false
}

variable "propagation_delay" {
  description = <<-EOT
    Delay before the role assignments are set, to let newly created groups
    propagate in Graph. A role assignment against a group that has not finished
    replicating will fail.
  EOT
  type        = string
  default     = "30s"
}
