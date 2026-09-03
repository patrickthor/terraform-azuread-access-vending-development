variable "cloud_prefix" {
  description = <<-EOT
    Default prefix on group names when a scope does not set `cloud` itself.
    "azure" yields azure-{scope}-{role} per the naming contract.

    Per-scope `cloud` overrides this, so Azure and AWS scopes can coexist in the
    same configuration.
  EOT
  type        = string
  default     = "azure"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.cloud_prefix))
    error_message = "cloud_prefix must be lowercase letters and digits, without hyphens."
  }
}

variable "access_scopes" {
  description = <<-EOT
    Access scopes and their roles. A scope is a target the access applies to: an
    Azure subscription, an AWS account, a GCP project, a GitHub org.

    Scope keys and role keys become part of the group name
    {cloud}-{scope}-{role}. One group carries exactly one role on one scope.
    Different access levels — reader/contributor/owner — are given as separate
    roles.

    Membership is not set here. It comes from the access package in repo 2.

    ---------------------------------------------------------------------------
    jit_mechanism selects where just-in-time lives:

      "azure_pim"       M2. PIM for Azure Resources. The group is NOT
                        PIM-managed; membership is active. The user activates the
                        ROLE. Requires cloud = "azure", azure_role and scope_id.

      "pim_for_groups"  M3. PIM for Groups. The group IS PIM-managed; the access
                        package grants EligibleMember and the user activates the
                        MEMBERSHIP. For AWS, GCP and GitHub, which have no
                        role-level JIT to activate. Authorization in the target
                        cloud happens on the cloud side via SCIM — see
                        modules/pim-group-access/README.md.

      "entra_role"      M4. Entra directory roles (Groups Administrator,
                        User Administrator, ...). The group is made
                        role-assignable and bound to the role, permanently or
                        eligible. Requires cloud = "entra".

                        WARNING: Terraform CANNOT set the activation rules for
                        directory roles. There is no policy resource in the
                        azuread provider (azuread_group_role_management_policy
                        applies to groups, not directory roles). MFA, approval
                        and max activation duration must be set in the PIM
                        portal. Therefore those fields are rejected here instead
                        of being silently ignored. See
                        modules/entra-role-access/README.md.
    ---------------------------------------------------------------------------
  EOT

  type = map(object({
    # Prefix for group names. null yields var.cloud_prefix.
    cloud = optional(string)

    # Azure subscription ID (GUID) when the scope has azure_pim roles. Otherwise
    # a free string — AWS account ID, GCP project ID, GitHub org name — and
    # purely for documentation.
    scope_id = optional(string)

    # One or more system owners, as UPN.
    #
    # All become approvers when approval_type is "owner" or "dual". Both provider
    # schemas accept multiple primary_approver (set without max), but only allow
    # ONE approval_stage — so multiple system owners are in the same stage, and
    # it is enough that one of them signs. If you want sequential approval, it
    # must be on the access package request in repo 2.
    #
    # Also become owners on the groups if set_systemeier_as_group_owner is true.
    systemeier = list(string)

    # The approver group for the scope — the one that approves together with
    # systemeier when approval_type is "dual".
    #
    # null (default) = the repo CREATES {cloud}-{scope}-approvers, seeded with
    # the systemeier as members so a "dual" role can be activated immediately.
    # Additional peer approvers should come from an access package in repo 2, so
    # that the wider approval right is vended like all other access.
    #
    # If set to a name, that group is looked up instead. It must already exist —
    # the repo does not create it.
    approver_group_name = optional(string)

    roles = map(object({
      jit_mechanism = optional(string, "azure_pim")

      # ---- azure_pim ----
      # Actual Azure RBAC role. Free string: "Reader", "Contributor",
      # "Storage Blob Data Reader".
      azure_role = optional(string)

      # false (default) = eligible assignment, the user activates the role.
      # true            = permanent binding. The time limit then comes from
      #                   expiry on the access package assignment in repo 2.
      permanent_access = optional(bool, false)

      # How long the group is eligible for the role. null = permanent eligibility.
      eligible_duration_days = optional(number)

      # ---- pim_for_groups ----
      # What the access corresponds to in the target cloud: AWS permission set,
      # GCP role, GitHub team role. Pure documentation — no resource binds it.
      target_role = optional(string)

      # Max duration for ACTIVE memberships. P15D/P30D/P90D/P180D/P365D.
      # The default "P30D" is set in root main.tf, for the same reason as the
      # activation fields below: null must be distinguishable from an explicitly
      # set value, so that the other mechanisms can reject the field.
      #
      # The sentinel "permanent" allows permanent ACTIVE memberships. It
      # undermines JIT and must be written explicitly — null gives the default,
      # not permanent.
      active_assignment_expire_after = optional(string)

      # Whether eligible assignments must have an expiry date. false lets the
      # access package own the lifecycle. Default is set in root main.tf.
      eligible_assignment_expiration_required = optional(bool)

      # Escape hatch for demo. Grants standing eligibility OUTSIDE the access
      # package flow. Should be empty in production.
      demo_eligible_user_principal_names = optional(list(string), [])

      # ---- entra_role ----
      # Display name of the directory role, e.g. "Groups Administrator". Looked
      # up against directoryRoleTemplates to find the template ID, which is what
      # roleDefinitionId actually needs. The role is activated in the tenant if
      # it is not already active.
      entra_role = optional(string)

      # Justification that accompanies the eligible request. Graph requires a
      # non-empty field here, so the module has a default.
      eligible_justification = optional(string)

      # ---- common ----
      # Applies to activation. No effect when permanent_access = true. The
      # defaults are null, not values. This is intentional: it is the only way to
      # distinguish "not set" from "set to the default value", and entra_role
      # cannot enforce any of them. If they had concrete defaults, entra_role
      # would have to silently ignore them.
      #
      # azure_pim and pim_for_groups get their defaults in root main.tf.
      #
      # approval_type determines WHO approves:
      #
      #   "self"   no approver
      #   "owner"  the systemeier list, as named users
      #   "dual"   the systemeier list AND the approver group, in the same stage
      #
      # The approver group is no longer a field per role: it follows the scope,
      # so all roles under a scope are approved by the same group.
      #
      # approver_group_name is here ONLY so it can be rejected. Terraform
      # silently drops unknown attributes when converting to an object type, so
      # if the field were missing from the type an old configuration would be
      # accepted and the approver group swapped out without a word. See the
      # validation below.
      approver_group_name   = optional(string)
      approval_type         = optional(string)
      max_activation_hours  = optional(number)
      require_mfa           = optional(bool)
      require_justification = optional(bool)
      require_ticket_info   = optional(bool)

      # Force-replace on azuread_group. Set true only if the group should also
      # carry Entra directory roles. See risk R3.
      assignable_to_role = optional(bool, false)
    }))
  }))

  default = {}

  # ---------------------------------------------------------------------------
  # Keys
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue([
      for scope_key in keys(var.access_scopes) : !can(regex("--", scope_key))
    ])
    error_message = "Scope keys cannot contain '--' (reserved as composite separator)."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role_key in keys(scope.roles) : !can(regex("--", role_key))
      ]
    ]))
    error_message = "Role keys cannot contain '--' (reserved as composite separator)."
  }

  validation {
    condition = alltrue([
      for scope_key in keys(var.access_scopes) : can(regex("^[a-z0-9-]+$", scope_key))
    ])
    error_message = "Scope keys must be lowercase letters, digits and hyphens — they become part of the group name."
  }

  # ---------------------------------------------------------------------------
  # systemeier
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue([
      for scope in values(var.access_scopes) : length(scope.systemeier) > 0
    ])
    error_message = "systemeier must have at least one UPN. Without a system owner there is no approver for approval_type = \"owner\", and no one responsible for the access."
  }

  validation {
    condition = alltrue([
      for scope in values(var.access_scopes) :
      length(distinct(scope.systemeier)) == length(scope.systemeier)
    ])
    error_message = "systemeier cannot contain duplicates. primary_approver is a set, so a duplicate would be silently swallowed and give a misleading impression of how many are approving."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for upn in scope.systemeier : can(regex("^[^@[:space:]]+@[^@[:space:]]+$", upn))
      ]
    ]))
    error_message = "Each systemeier must be a UPN in the form user@domain. Guest users are written with #EXT#, e.g. name_company.com#EXT#@tenant.onmicrosoft.com."
  }

  # ---------------------------------------------------------------------------
  # Discriminator
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        contains(["azure_pim", "pim_for_groups", "entra_role"], role.jit_mechanism)
      ]
    ]))
    error_message = "jit_mechanism must be \"azure_pim\" (M2, PIM for Azure Resources), \"pim_for_groups\" (M3, PIM for Groups) or \"entra_role\" (M4, Entra directory roles)."
  }

  # ---------------------------------------------------------------------------
  # azure_pim requirements
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "azure_pim" ? role.azure_role != null : true
      ]
    ]))
    error_message = "azure_role must be set when jit_mechanism = \"azure_pim\" — it is the role bound at the subscription scope."
  }

  validation {
    # The trap this closes: cloud = "aws" with jit_mechanism = "azure_pim" would
    # produce a group called aws-{scope}-{role} bound to Azure RBAC. The name
    # lies about what the membership provides, and the configuration applies
    # cleanly.
    condition = alltrue([
      for scope in values(var.access_scopes) :
      coalesce(scope.cloud, var.cloud_prefix) == "azure"
      if anytrue([for role in values(scope.roles) : role.jit_mechanism == "azure_pim"])
    ])
    error_message = "A scope with azure_pim roles must have cloud = \"azure\". PIM for Azure Resources binds Azure RBAC, so a different prefix would produce a group name that lies about what the access provides. Use jit_mechanism = \"pim_for_groups\" for other clouds."
  }

  validation {
    condition = alltrue([
      for scope in values(var.access_scopes) :
      scope.scope_id != null && can(regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        coalesce(scope.scope_id, "")
      ))
      if anytrue([for role in values(scope.roles) : role.jit_mechanism == "azure_pim"])
    ])
    error_message = "A scope with azure_pim roles must have scope_id set to an Azure subscription ID (GUID)."
  }

  # ---------------------------------------------------------------------------
  # pim_for_groups requirements
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "pim_for_groups" ? role.azure_role == null : true
      ]
    ]))
    error_message = "azure_role cannot be set when jit_mechanism = \"pim_for_groups\". It would be ignored — the pim_for_groups track creates no Azure role binding. Use target_role to document what the access corresponds to in the target cloud."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "pim_for_groups" ? !role.permanent_access : true
      ]
    ]))
    error_message = "permanent_access = true is meaningless with jit_mechanism = \"pim_for_groups\": the whole point there is that the MEMBERSHIP is time-limited. A permanent variant is a regular group without PIM."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "pim_for_groups" ? try(length(role.target_role), 0) > 0 : true
      ]
    ]))
    error_message = "target_role must be set when jit_mechanism = \"pim_for_groups\". The module does not connect the group to the target cloud — target_role is the only place where it is documented what the group should provide, and whoever sets up SCIM needs it."
  }

  validation {
    # "permanent" is a sentinel that root main.tf translates to null, which is
    # what the provider interprets as "no expiry limit". It must be written
    # explicitly because it undermines JIT — it should not be something you
    # achieve by omitting a field.
    #
    # Nulls filtered rather than guarded with `||` — see the approval_type
    # validation. This one did not crash before, because the coalesce() meant
    # contains() never actually saw the null. That was luck, not design.
    condition = alltrue([
      for v in flatten([
        for scope in values(var.access_scopes) : [
          for role in values(scope.roles) : role.active_assignment_expire_after
          if role.active_assignment_expire_after != null
        ]
      ]) : contains(["P15D", "P30D", "P90D", "P180D", "P365D", "permanent"], v)
    ])
    error_message = "active_assignment_expire_after must be P15D, P30D, P90D, P180D or P365D. null gives the default P30D. \"permanent\" allows permanent ACTIVE memberships and removes the JIT guarantee for them — it must be written explicitly."
  }

  # ---------------------------------------------------------------------------
  # entra_role requirements (M4)
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "entra_role" ? try(length(role.entra_role), 0) > 0 : true
      ]
    ]))
    error_message = "entra_role must be set when jit_mechanism = \"entra_role\" — the display name of the directory role, e.g. \"Groups Administrator\"."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "entra_role" ? (role.azure_role == null && role.target_role == null) : true
      ]
    ]))
    error_message = "azure_role and target_role cannot be set when jit_mechanism = \"entra_role\". Use entra_role."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism != "entra_role" ? role.entra_role == null : true
      ]
    ]))
    error_message = "entra_role can only be set when jit_mechanism = \"entra_role\". It would be ignored by the other tracks."
  }

  validation {
    # Core limitation in M4: the azuread provider has no policy resource for
    # directory roles. azuread_group_role_management_policy applies to GROUPS.
    # The activation rules for a directory role must be set in the PIM portal,
    # and Terraform cannot read or enforce them.
    #
    # Silently ignoring these fields would be a security lie: someone writes
    # require_mfa = true and believes MFA is enforced.
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism == "entra_role" ? (
          role.approval_type == null &&
          role.max_activation_hours == null &&
          role.require_mfa == null &&
          role.require_justification == null &&
          role.require_ticket_info == null
        ) : true
      ]
    ]))
    error_message = "approval_type, max_activation_hours, require_mfa, require_justification and require_ticket_info cannot be set when jit_mechanism = \"entra_role\". Terraform cannot enforce them for directory roles — there is no policy resource in the azuread provider. Set them in the PIM portal instead, otherwise the configuration would lie about what is enforced."
  }

  validation {
    # Directory roles are tenant-global or scoped to an administrative unit.
    # There is no subscription to attach them to.
    condition = alltrue([
      for scope in values(var.access_scopes) :
      coalesce(scope.cloud, var.cloud_prefix) == "entra"
      if anytrue([for role in values(scope.roles) : role.jit_mechanism == "entra_role"])
    ])
    error_message = "A scope with entra_role roles must have cloud = \"entra\". The group name should indicate that the access applies to directory roles, not a cloud."
  }

  validation {
    condition = alltrue([
      for scope in values(var.access_scopes) :
      coalesce(scope.scope_id, "/") == "/" || can(regex("^/administrativeUnits/[0-9a-fA-F-]{36}$", coalesce(scope.scope_id, "/")))
      if anytrue([for role in values(scope.roles) : role.jit_mechanism == "entra_role"])
    ])
    error_message = "For entra_role, scope_id must be \"/\" (the whole tenant) or \"/administrativeUnits/<guid>\". That is directory_scope_id as Graph expects it."
  }

  # ---------------------------------------------------------------------------
  # Common requirements
  # ---------------------------------------------------------------------------

  validation {
    # NULLS ARE FILTERED OUT BEFORE contains(), NOT GUARDED WITH `||`.
    #
    # `x == null || contains(list, x)` looks like a null guard but is not one:
    # Terraform's `||` does not reliably short-circuit, so contains() still
    # receives the null and fails with
    #   "Invalid value for \"value\" parameter: argument must not be null."
    #
    # This was a real failure when the module was consumed from a git source —
    # any role omitting approval_type broke plan, even though omitting it is
    # documented and intended. A ternary is not a dependable fix either, for the
    # same reason. Filtering in the `for` clause is: the value is never passed to
    # a function at all.
    #
    # Same pattern applies to every nullable field validated in this file.
    condition = alltrue([
      for v in flatten([
        for scope in values(var.access_scopes) : [
          for role in values(scope.roles) : role.approval_type
          if role.approval_type != null
        ]
      ]) : contains(["self", "owner", "dual"], v)
    ])
    error_message = "approval_type must be one of: self, owner, dual. null gives the default (owner) for azure_pim and pim_for_groups."
  }

  # ---------------------------------------------------------------------------
  # Approver group per scope
  # ---------------------------------------------------------------------------

  validation {
    # {cloud}-{scope}-approvers is the name the repo gives the approver group. A
    # role with key "approvers" would produce the same group name and collide.
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role_key in keys(scope.roles) : role_key != "approvers"
      ]
    ]))
    error_message = "Role key \"approvers\" is reserved. The approver group for a scope is named {cloud}-{scope}-approvers, so a role with that key would produce two groups with the same name."
  }

  validation {
    # The field has been MOVED from role level to scope level. This validation
    # exists only to say so explicitly: without it Terraform would silently drop
    # the attribute, and an old configuration would get a different approver than
    # it asks for.
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) : role.approver_group_name == null
      ]
    ]))
    error_message = "approver_group_name has been moved from role level to scope level. The approver group now applies to all roles under a scope, and is created as {cloud}-{scope}-approvers if you do not provide a name. Move the field up next to systemeier, or remove it to get the group the repo creates."
  }

  validation {
    # entra_role has no approval at all — Terraform cannot set activation rules
    # for directory roles. An approver group on a scope that only has entra_role
    # roles would never be used.
    condition = alltrue([
      for scope in values(var.access_scopes) :
      scope.approver_group_name == null
      if !anytrue([
        for role in values(scope.roles) :
        role.jit_mechanism != "entra_role" && coalesce(role.approval_type, "owner") == "dual"
      ])
    ])
    error_message = "approver_group_name can only be set on a scope that has at least one role with approval_type \"dual\". Otherwise the group would never be used as an approver, and the configuration would imply an approval that does not exist."
  }

  validation {
    # Nulls filtered out before the comparison — see the approval_type
    # validation above. A raw null reaching `>=` fails with
    # "Error during operation: argument must not be null."
    condition = alltrue([
      for v in flatten([
        for scope in values(var.access_scopes) : [
          for role in values(scope.roles) : role.max_activation_hours
          if role.max_activation_hours != null
        ]
      ]) : v >= 1 && v <= 23
    ])
    error_message = "max_activation_hours must be between 1 and 23 (activation duration limit). null gives the default (8)."
  }

  validation {
    # Azure only accepts a fixed set of durations for eligible assignment expiry.
    #
    # Nulls filtered rather than guarded with `||` — see the approval_type
    # validation.
    condition = alltrue([
      for v in flatten([
        for scope in values(var.access_scopes) : [
          for role in values(scope.roles) : role.eligible_duration_days
          if role.eligible_duration_days != null
        ]
      ]) : contains([15, 30, 90, 180, 365], v)
    ])
    error_message = "eligible_duration_days must be 15, 30, 90, 180 or 365 — Azure only accepts P15D/P30D/P90D/P180D/P365D. null gives permanent eligibility, which requires that the policy allows it."
  }

  # ---------------------------------------------------------------------------
  # Fields that belong to ONE mechanism
  #
  # A field that does not apply to the chosen mechanism is never read by the
  # dispatch in main.tf. Letting it pass silently would produce a configuration
  # that looks like it controls something it does not. Same principle as for the
  # activation fields on entra_role.
  # ---------------------------------------------------------------------------

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism != "azure_pim" ? role.eligible_duration_days == null : true
      ]
    ]))
    error_message = "eligible_duration_days only applies to azure_pim — it sets expiry on eligible Azure role assignments. pim_for_groups uses eligible_assignment_expiration_required, and entra_role cannot set expiry on eligibility at all (azuread_directory_role_eligibility_schedule_request has no schedule block)."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism != "pim_for_groups" ? (
          role.active_assignment_expire_after == null &&
          role.eligible_assignment_expiration_required == null
        ) : true
      ]
    ]))
    error_message = "active_assignment_expire_after and eligible_assignment_expiration_required only apply to pim_for_groups — they are rules in the group's activation policy. azure_pim controls duration with eligible_duration_days, and entra_role has no policy Terraform can write to."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism != "entra_role" ? role.eligible_justification == null : true
      ]
    ]))
    error_message = "eligible_justification only applies to entra_role — Graph requires a non-empty justification field on directoryRoleEligibilityScheduleRequest. The other mechanisms have no corresponding request to attach it to."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism != "pim_for_groups" ? length(role.demo_eligible_user_principal_names) == 0 : true
      ]
    ]))
    error_message = "demo_eligible_user_principal_names only applies to pim_for_groups. It is an escape hatch that grants a user eligibility for the GROUP outside the access package flow — the other mechanisms assign to the group, not to users."
  }

  validation {
    condition = alltrue(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) :
        role.jit_mechanism != "pim_for_groups" ? role.target_role == null : true
      ]
    ]))
    error_message = "target_role only applies to pim_for_groups — it is the documentation field for what the group should correspond to in the target cloud. azure_pim uses azure_role, entra_role uses entra_role."
  }

  validation {
    # azurerm_role_management_policy is keyed on (ARM scope, role) — not per
    # group, and not per scope KEY. The check therefore uses scope_id, so that
    # two different scope keys pointing at the SAME subscription are also caught.
    # This is a real scenario: multiple logical scopes can share one test
    # subscription.
    #
    # pim_for_groups does not have this problem: there the policy is keyed on
    # (group_id, assignment_type), and with one group per role it is unique.
    condition = length(distinct(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) : "${coalesce(scope.scope_id, "")}|${role.azure_role}"
        if role.jit_mechanism == "azure_pim" && !role.permanent_access
      ]
      ]))) == length(flatten([
      for scope in values(var.access_scopes) : [
        for role in values(scope.roles) : "${coalesce(scope.scope_id, "")}|${role.azure_role}"
        if role.jit_mechanism == "azure_pim" && !role.permanent_access
      ]
    ]))
    error_message = "Two eligible azure_pim roles cannot have the same azure_role on the same subscription — the activation policy is keyed on (scope, role) and they would collide. Note that this applies across scope keys if they share the same scope_id. Set permanent_access = true on one of them, or merge them."
  }
}

variable "group_description_template" {
  description = <<-EOT
    Template for group description. Placeholders: {cloud}, {sub}, {role},
    {target_role}, {scope_id}.

    {target_role} is the Azure RBAC role in the azure_pim track and the
    target_role field in the pim_for_groups track, so one template works for
    both.

    null gives each mechanism its own default, which mentions the correct JIT
    model.
  EOT
  type        = string
  default     = null
}

variable "set_systemeier_as_group_owner" {
  description = <<-EOT
    Whether systemeier should be set as owners on the groups. Default false, on
    purpose.

    A group owner can manage membership directly and thus bypass the access
    package. Since membership is managed outside Terraform, such a bypass would
    never be flagged in a plan. Systemeier does not need to be an owner to be an
    approver.

    In the pim_for_groups track the consequence is greater: a directly added
    member is an ACTIVE member, not eligible, and thus bypasses the entire PIM
    activation with approval and MFA.
  EOT
  type        = bool
  default     = false
}

variable "pim_group_propagation_delay" {
  description = <<-EOT
    Wait time before PIM resources are created on newly created groups, so they
    can propagate in Graph. Only applies to the pim_for_groups track. Set "0s" if
    the groups are known to already exist.
  EOT
  type        = string
  default     = "30s"
}
