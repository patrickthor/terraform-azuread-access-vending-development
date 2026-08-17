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
