variable "groups" {
  description = <<-EOT
    Groups to create, keyed on a stable identifier.

    `name` is pre-prefixed by the caller (e.g. "azure-sub-alpha-reader").
    The module does not add a prefix itself — that is the caller's
    responsibility, so the same module can be used for aws-/gcp- prefixes later.
  EOT

  type = map(object({
    name        = string
    description = optional(string, "")

    # Owners and permanent members, as UPN. Permanent members are normally empty
    # in this POC: membership comes from access package or PIM activation.
    owner_user_principal_names  = optional(list(string), [])
    member_user_principal_names = optional(list(string), [])

    # Force-replace in Entra. Set true only if the group will carry
    # Entra directory roles.
    assignable_to_role = optional(bool, false)
  }))

  default = {}

  validation {
    condition = alltrue([
      for g in values(var.groups) : can(regex("^[a-zA-Z0-9-]+$", g.name))
    ])
    error_message = "Group names may only contain letters, digits and hyphens (mail_nickname is set to the same value)."
  }

  validation {
    condition     = alltrue([for g in values(var.groups) : length(g.name) <= 64])
    error_message = "Group names must be 64 characters or shorter."
  }
}

variable "prevent_duplicate_names" {
  description = <<-EOT
    Fails apply if a group with the same display_name already exists. Recommended
    true: display_name is the lookup key against the access-package repo, and a
    manually created duplicate would otherwise cause ambiguous lookup there.
  EOT
  type        = bool
  default     = true
}
