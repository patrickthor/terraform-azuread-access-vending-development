# ==============================================================================
# Root module — vending
#
# Dispatches per JIT mechanism. The roles in a scope are split by jit_mechanism
# and sent to their respective composite:
#
#   azure_pim       -> azure-subscription-access   (azuread + azurerm)
#   pim_for_groups  -> pim-group-access            (azuread + time)
#   entra_role      -> entra-role-access           (azuread + time)
#
# The split is by ROLE, not scope, so a scope can in principle have several.
# This also gives provider isolation: the M3 and M4 paths never pull in azurerm.
#
# All logic is in the modules; this file is kept thin so it can be lifted
# straight into the LZ repo.
# ==============================================================================

locals {
  # ----------------------------------------------------------------------------
  # Approver group per scope
  #
  # One group per scope approves ALL roles under the scope. It replaces what was
  # previously an approver_group_name per role. The group is seeded with the
  # systemeier so it is never empty, and additional peer approvers are layered on
  # via an access package in repo 2.
  #
  # The group is only created when someone actually approves via a group —
  # approval_type "dual". Roles with "owner" are approved by the systemeier
  # list directly, and "self" has no approver. entra_role has no approval at
  # all.
  # ----------------------------------------------------------------------------

  scopes_with_group_approval = {
    for scope_key, scope in var.access_scopes : scope_key => scope
    if anytrue([
      for role in values(scope.roles) :
      role.jit_mechanism != "entra_role" && coalesce(role.approval_type, "owner") == "dual"
    ])
  }

  # Scopes that should have the group CREATED here. If the scope specifies a
  # name, that group is looked up instead — see the data block below.
  approver_groups_to_create = {
    for scope_key, scope in local.scopes_with_group_approval :
    scope_key => {
      name = "${coalesce(scope.cloud, var.cloud_prefix)}-${scope_key}-approvers"

      description = "Approver group for scope ${scope_key}. Members approve activation of the roles under the scope. Seeded with the systemeier; additional peers are assigned via access package. Managed by Terraform."

      # The systemeier are seeded as MEMBERS. This grants them nothing new — they
      # are already named approvers for approval_type "owner" and "dual" — but it
      # guarantees the group is never empty. An empty approver group means a
      # "dual" role cannot be activated at all: PIM has no default approvers for
      # azure_pim or pim_for_groups, and the request dies of timeout after 24
      # hours.
      #
      # Additional approvers (peers) are layered on top via an access package in
      # repo 2. That is safe: entra-groups manages membership with individual
      # azuread_group_member resources and has ignore_changes on the group's
      # members attribute, so members added outside Terraform are not removed.
      #
      # No OWNERS, deliberately. A group owner can manage membership directly,
      # which would let someone grant themselves approval authority. Members
      # cannot.
      owner_user_principal_names  = []
      member_user_principal_names = scope.systemeier
      assignable_to_role          = false
    }
    if scope.approver_group_name == null
  }

  approver_group_lookup_names = toset([
    for scope in values(local.scopes_with_group_approval) : scope.approver_group_name
    if scope.approver_group_name != null
  ])

  # Object ID per scope, regardless of whether the group was created or looked up.
  approver_group_object_ids = {
    for scope_key, scope in local.scopes_with_group_approval :
    scope_key => scope.approver_group_name == null
    ? module.approver_groups.group_object_ids[scope_key]
    : data.azuread_group.scope_approvers[scope.approver_group_name].object_id
  }

  approver_group_names = {
    for scope_key, scope in local.scopes_with_group_approval :
    scope_key => coalesce(
      scope.approver_group_name,
      "${coalesce(scope.cloud, var.cloud_prefix)}-${scope_key}-approvers"
    )
  }

  # Roles are explicitly projected into each composite's interface rather than
  # being passed through as-is. This makes it visible which fields each mechanism
  # actually uses, and a field that does not belong cannot be smuggled through.

  azure_pim_scopes = {
    for scope_key, scope in var.access_scopes : scope_key => {
      cloud      = coalesce(scope.cloud, var.cloud_prefix)
      scope_id   = scope.scope_id
      systemeier = scope.systemeier

      roles = {
        for role_key, role in scope.roles : role_key => {
          azure_role       = role.azure_role
          permanent_access = role.permanent_access

          # Defaults live here, not in the variable type. See the comment in
          # variables.tf: null in tfvars must be distinguishable from an
          # explicitly set value, so that entra_role can reject fields it cannot
          # enforce.
          approval_type         = coalesce(role.approval_type, "owner")
          max_activation_hours  = coalesce(role.max_activation_hours, 8)
          require_mfa           = coalesce(role.require_mfa, false)
          require_justification = coalesce(role.require_justification, true)
          require_ticket_info   = coalesce(role.require_ticket_info, false)

          eligible_duration_days = role.eligible_duration_days
          assignable_to_role     = role.assignable_to_role
        }
        if role.jit_mechanism == "azure_pim"
      }
    }
    if anytrue([for role in values(scope.roles) : role.jit_mechanism == "azure_pim"])
  }

  pim_group_scopes = {
    for scope_key, scope in var.access_scopes : scope_key => {
      cloud      = coalesce(scope.cloud, var.cloud_prefix)
      scope_id   = coalesce(scope.scope_id, "")
      systemeier = scope.systemeier

      roles = {
        for role_key, role in scope.roles : role_key => {
          target_role = coalesce(role.target_role, "")

          approval_type         = coalesce(role.approval_type, "owner")
          max_activation_hours  = coalesce(role.max_activation_hours, 8)
          require_mfa           = coalesce(role.require_mfa, false)
          require_justification = coalesce(role.require_justification, true)
          require_ticket_info   = coalesce(role.require_ticket_info, false)

          # The sentinel "permanent" is passed through AS A STRING, not
          # translated to null. The reason was learned from a bug:
          # `optional(string, "P30D")` in the receiver replaces explicit null
          # with the default, so a null-based sentinel disappears without a trace
          # and yields P30D. Verified empirically.
          #
          # The translation therefore happens all the way down, in
          # pim-for-groups, where it can set `expiration_required = false` at the
          # same time. Without the latter, "permanent" is meaningless:
          # expire_after is Optional+Computed, so null there does not remove any
          # limit — it is expiration_required that determines whether the limit
          # applies at all.
          active_assignment_expire_after = coalesce(role.active_assignment_expire_after, "P30D")

          eligible_assignment_expiration_required = coalesce(role.eligible_assignment_expiration_required, false)
          demo_eligible_user_principal_names      = role.demo_eligible_user_principal_names

          assignable_to_role = role.assignable_to_role
        }
        if role.jit_mechanism == "pim_for_groups"
      }
    }
    if anytrue([for role in values(scope.roles) : role.jit_mechanism == "pim_for_groups"])
  }

  entra_role_scopes = {
    for scope_key, scope in var.access_scopes : scope_key => {
      cloud      = coalesce(scope.cloud, var.cloud_prefix)
      systemeier = scope.systemeier

      # For entra_role, scope_id IS directory_scope_id. "/" is the whole tenant.
      directory_scope_id = coalesce(scope.scope_id, "/")

      roles = {
        for role_key, role in scope.roles : role_key => {
          entra_role       = role.entra_role
          permanent_access = role.permanent_access

          # No activation fields here. The root validation rejects them for
          # entra_role, because Terraform cannot enforce them for directory roles.
          # See modules/entra-role-access/main.tf.
          eligible_justification = coalesce(
            role.eligible_justification,
            "Created by access vending (Terraform)"
          )
        }
        if role.jit_mechanism == "entra_role"
      }
    }
    if anytrue([for role in values(scope.roles) : role.jit_mechanism == "entra_role"])
  }

  # ============================================================================
  # THE MACHINE CONTRACT
  #
  # One output, consumed as repo 2's only input. The 22 human-readable outputs
  # stay as they are — they are good for reading a plan. This is the machine part.
  #
  # THE ONE RULE: every map key and every list element below must be derivable
  # from var.access_scopes alone. Never key a contract map, or populate a contract
  # list, from a resource attribute.
  #
  # Repo 2 uses contract.roles, contract.scopes, contract.catalogs, role_keys and
  # scope_keys as for_each sources, and for_each needs keys known at PLAN time.
  # Values inside the maps may be unknown until apply — group_object_id always is
  # — and that is fine, because unknown values only break for_each and count.
  #
  # A regression here does not fail in this repo. It surfaces in repo 2 as
  # "The for_each value depends on resource attributes that cannot be determined
  # until apply", for a change made here. Run a plan against an empty tenant
  # whenever this assembly changes.
  # ============================================================================

  # ISO-8601 durations mapped to days, so neither repo parses ISO-8601 and no
  # human keeps a duplicated ceiling in sync. "permanent" is deliberately absent:
  # it falls through the lookup below to null.
  expire_after_days = {
    P15D  = 15
    P30D  = 30
    P90D  = 90
    P180D = 180
    P365D = 365
  }

  # Every (scope, role) pair flattened once, from the VARIABLE only. Everything
  # else in the contract is derived from this list, so there is a single place
  # where the plan-time guarantee has to hold.
  contract_role_entries = flatten([
    for scope_key, scope in var.access_scopes : [
      for role_key, role in scope.roles : {
        composite = "${scope_key}--${role_key}"
        scope_key = scope_key
        role_key  = role_key
        mechanism = role.jit_mechanism
        role      = role
      }
    ]
  ])

  # Effective expiry per composite key, for pim_for_groups only. The coalesce
  # mirrors the default applied in pim_group_scopes above, so the contract
  # reports the ceiling that is actually in force rather than what was typed.
  #
  # The expiry-drift trap only exists for pim_for_groups: if a package assignment
  # outlives the group's eligible-assignment expiry, PIM expires the eligibility
  # while Entitlement Management still lists the user as assigned. Nothing errors
  # and the user's MyAccess page contradicts what they can actually do.
  contract_expire_after = {
    for entry in local.contract_role_entries :
    entry.composite => coalesce(entry.role.active_assignment_expire_after, "P30D")
    if entry.mechanism == "pim_for_groups"
  }

  # Group name and object ID per composite key.
  #
  # The KEYS here come from the mechanism scope maps above, which are themselves
  # built from var.access_scopes — so they are plan-known. Only the VALUES come
  # from module outputs. This is the distinction that matters: merging maps whose
  # keys came out of a module would make the contract's key set unknown at plan
  # time, which is exactly what breaks repo 2.
  #
  # The name is READ BACK from the submodules rather than recalculated here. The
  # naming formula lives in one place only.
  group_facts = merge(
    merge([
      for scope_key, scope in local.azure_pim_scopes : {
        for role_key in keys(scope.roles) : "${scope_key}--${role_key}" => {
          group_name      = module.azure_pim_access[scope_key].group_names[role_key]
          group_object_id = module.azure_pim_access[scope_key].group_object_ids[role_key]
          access_type     = "Member"
        }
      }
    ]...),
    merge([
      for scope_key, scope in local.pim_group_scopes : {
        for role_key in keys(scope.roles) : "${scope_key}--${role_key}" => {
          group_name      = module.pim_group_access[scope_key].group_names[role_key]
          group_object_id = module.pim_group_access[scope_key].group_object_ids[role_key]
          access_type     = module.pim_group_access[scope_key].access_package_access_type[role_key]
        }
      }
    ]...),
    merge([
      for scope_key, scope in local.entra_role_scopes : {
        for role_key in keys(scope.roles) : "${scope_key}--${role_key}" => {
          group_name      = module.entra_role_access[scope_key].group_names[role_key]
          group_object_id = module.entra_role_access[scope_key].group_object_ids[role_key]
          access_type     = module.entra_role_access[scope_key].access_package_access_type[role_key]
        }
      }
    ]...),
  )

  # Catalog LABEL per scope. This repo creates no catalogs and does not know what
  # one is; it validates the string and forwards it.
  scope_catalog = {
    for scope_key, scope in var.access_scopes :
    scope_key => coalesce(scope.catalog, var.default_catalog)
  }

  # ---- the three contract maps, named so the guarantee is reviewable ----------

  contract_roles = {
    for entry in local.contract_role_entries : entry.composite => {
      scope = entry.scope_key
      role  = entry.role_key

      group_name      = local.group_facts[entry.composite].group_name
      group_object_id = local.group_facts[entry.composite].group_object_id

      # repo 1's ANSWER, not repo 2's guess. Repo 2 must never default a missing
      # access_type: defaulting to "Member" turns JIT eligibility into standing
      # membership, the apply succeeds, the portal looks right, and the user
      # silently holds access they should have had to activate for.
      access_type = local.group_facts[entry.composite].access_type

      jit_mechanism    = entry.mechanism
      permanent_access = entry.role.permanent_access

      # The RBAC role, target-cloud role, or directory role, depending on
      # mechanism. Exactly one of the three is set — the variable validations
      # reject the others.
      target = coalesce(
        entry.role.azure_role,
        entry.role.target_role,
        entry.role.entra_role,
        "",
      )

      # null for azure_pim and entra_role, and null for the "permanent" sentinel.
      # None of the three is a key in expire_after_days, so one lookup with a null
      # default covers every case.
      max_assignment_days = lookup(
        local.expire_after_days,
        lookup(local.contract_expire_after, entry.composite, "permanent"),
        null,
      )
    }
  }

  contract_scopes = {
    for scope_key, scope in var.access_scopes : scope_key => {
      catalog    = local.scope_catalog[scope_key]
      cloud      = coalesce(scope.cloud, var.cloud_prefix)
      scope_id   = scope.scope_id
      systemeier = scope.systemeier

      # Keyed on SCOPE, not composite key: one approver group serves every role
      # under a scope. Null where no role uses approval_type "dual" — repo 2 must
      # tolerate a scope with no approver group.
      approver_group_name      = lookup(local.approver_group_names, scope_key, null)
      approver_group_object_id = lookup(local.approver_group_object_ids, scope_key, null)

      # Explicit sorted list rather than leaving repo 2 to compute it. Naming it
      # is what makes the plan-time guarantee reviewable instead of accidental.
      role_keys = sort([
        for role_key in keys(scope.roles) : "${scope_key}--${role_key}"
      ])
    }
  }

  contract_catalogs = {
    for label in distinct(values(local.scope_catalog)) : label => {
      scope_keys = sort([
        for scope_key, scope_label in local.scope_catalog : scope_key
        if scope_label == label
      ])
    }
  }

  # ---- warning-level note, deliberately NOT a validation ---------------------
  #
  # Directory-role access is the highest-privilege thing this system vends, so it
  # should be easy to spot in a catalog listing. But sharing a catalog is a
  # legitimate choice — one identity team owning everything means one catalog is
  # correct — so this reports rather than rejects.
  entra_only_scopes_sharing_catalog = sort([
    for scope_key, scope in var.access_scopes : scope_key
    if alltrue([for role in values(scope.roles) : role.jit_mechanism == "entra_role"])
    && length(local.contract_catalogs[local.scope_catalog[scope_key]].scope_keys) > 1
  ])
}

# ------------------------------------------------------------------------------
# Approver groups
#
# Created in the root, not in the composites, because ONE scope can have roles
# in multiple mechanisms. If they were in the composites, a scope with both
# azure_pim and pim_for_groups roles would get two groups with the same name.
#
# The group is seeded with the systemeier — see the comment on
# approver_groups_to_create for why. Additional peer approvers come from an
# access package in repo 2, which is safe because entra-groups manages
# membership with individual azuread_group_member resources.
# ------------------------------------------------------------------------------

module "approver_groups" {
  source = "./modules/entra-groups"

  groups                  = local.approver_groups_to_create
  prevent_duplicate_names = true
}

data "azuread_group" "scope_approvers" {
  for_each     = local.approver_group_lookup_names
  display_name = each.value
}

# ------------------------------------------------------------------------------
# M2 — PIM for Azure Resources. JIT is in the ROLE.
# ------------------------------------------------------------------------------

module "azure_pim_access" {
  source   = "./modules/azure-subscription-access"
  for_each = local.azure_pim_scopes

  subscription_key = each.key
  subscription_id  = each.value.scope_id
  systemeier       = each.value.systemeier
  roles            = each.value.roles

  approver_group_object_id = lookup(local.approver_group_object_ids, each.key, null)

  cloud_prefix                  = each.value.cloud
  group_description_template    = var.group_description_template
  set_systemeier_as_group_owner = var.set_systemeier_as_group_owner
}

# ------------------------------------------------------------------------------
# M3 — PIM for Groups. JIT is in the MEMBERSHIP.
#
# Creates the group and the activation rules. The binding to the target cloud
# (AWS permission set, GCP IAM, GitHub team) happens on the cloud side via
# SCIM — see modules/pim-group-access/README.md and the target_cloud_bindings
# output.
# ------------------------------------------------------------------------------

module "pim_group_access" {
  source   = "./modules/pim-group-access"
  for_each = local.pim_group_scopes

  scope_key  = each.key
  scope_id   = each.value.scope_id
  systemeier = each.value.systemeier
  roles      = each.value.roles

  approver_group_object_id = lookup(local.approver_group_object_ids, each.key, null)

  cloud_prefix                  = each.value.cloud
  group_description_template    = var.group_description_template
  set_systemeier_as_group_owner = var.set_systemeier_as_group_owner
  propagation_delay             = var.pim_group_propagation_delay
}

# ------------------------------------------------------------------------------
# M4 — Entra directory roles. JIT is in the ROLE, but Terraform cannot set the
# activation rules.
#
# The groups here are role-assignable, which is force-replace in Entra. They can
# therefore not be reused from M2 or M3, and cannot be converted after the fact.
# See risk R3.
# ------------------------------------------------------------------------------

module "entra_role_access" {
  source   = "./modules/entra-role-access"
  for_each = local.entra_role_scopes

  scope_key          = each.key
  directory_scope_id = each.value.directory_scope_id
  systemeier         = each.value.systemeier
  roles              = each.value.roles

  cloud_prefix                  = each.value.cloud
  group_description_template    = var.group_description_template
  set_systemeier_as_group_owner = var.set_systemeier_as_group_owner
  propagation_delay             = var.pim_group_propagation_delay
}
