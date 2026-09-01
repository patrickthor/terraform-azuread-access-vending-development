# ==============================================================================
# entra-role-access — composite for M4 (Entra directory roles)
#
# Wrapper for entra-groups and binds each group to one directory role, permanent
# or eligible.
#
# Difference from the two other composite modules:
#
#   M2  azure-subscription-access   JIT in the ROLE, via PIM for Azure Resources.
#                                   ARM plane. Terraform sets the activation
#                                   rules itself.
#   M3  pim-group-access            JIT in the MEMBERSHIP, via PIM for Groups.
#                                   Terraform sets the activation rules itself.
#   M4  this one                    JIT in the ROLE, via PIM for Entra roles.
#                                   Terraform CANNOT set the activation rules.
#
# ------------------------------------------------------------------------------
# THE MOST IMPORTANT GAP IN THIS MODULE
#
# The azuread provider has no policy resource for directory roles.
# azuread_group_role_management_policy takes group_id and applies to GROUPS, not
# directory roles. There is no azuread_directory_role_management_policy.
#
# Consequence: MFA, approval, max activation duration, and justification
# requirements for an eligible directory role must be set in the PIM portal.
# Terraform neither reads nor enforces them, and cannot detect if they are
# changed.
#
# The root module therefore rejects approval_type, require_mfa,
# max_activation_hours, and the other activation fields for entra_role roles,
# instead of accepting them and ignoring them. See the output
# activation_governance_gap.
# ==============================================================================

data "azuread_directory_role_templates" "all" {}

locals {
  # Group name per role. Same naming contract as M2 and M3.
  group_names = {
    for role_key in keys(var.roles) :
    role_key => "${var.cloud_prefix}-${var.scope_key}-${role_key}"
  }

  description_template = coalesce(
    var.group_description_template,
    "Access group for Entra directory role {target_role} ({role}) on {sub}. Managed by Terraform."
  )

  group_descriptions = {
    for role_key, role in var.roles :
    role_key => replace(
      replace(
        replace(
          replace(
            replace(local.description_template, "{cloud}", var.cloud_prefix),
            "{sub}", var.scope_key
          ),
          "{role}", role_key
        ),
        "{target_role}", role.entra_role
      ),
      "{scope_id}", var.directory_scope_id
    )
  }

  # display_name -> template_id.
  #
  # NOTE: object_id on a roleTemplate IS the template ID. That is the
  # roleDefinitionId it needs. The activated directoryRole has a DIFFERENT
  # object_id, and it is always different from the template ID — mixing them
  # gives 400 from Graph.
  template_by_name = {
    for t in data.azuread_directory_role_templates.all.role_templates :
    t.display_name => t.object_id
  }

  # Unique role names that are requested. Multiple role keys can point to the
  # same directory role, and the role should only be activated once.
  requested_role_names = toset([for r in values(var.roles) : r.entra_role])

}

# ------------------------------------------------------------------------------
# System owners
#
# Only looked up if they are actually to be set as group owners. Unlike M2 and
# M3, they are not approvers here — Terraform cannot set approvers for
# directory roles.
# ------------------------------------------------------------------------------

data "azuread_user" "systemeier" {
  for_each            = var.set_systemeier_as_group_owner ? toset(var.systemeier) : toset([])
  user_principal_name = each.value
}

# ------------------------------------------------------------------------------
# 1) Activate the directory role in the tenant
#
# A role must be activated before it can be assigned. Most tenants only have a
# handful activated beforehand. The resource is idempotent: if the role is
# already active, it is adopted.
# ------------------------------------------------------------------------------

resource "azuread_directory_role" "this" {
  for_each = local.requested_role_names

  # Intentional lookup with default instead of direct indexing: that way the
  # precondition below can give an understandable error message before the
  # provider complains.
  template_id = lookup(local.template_by_name, each.value, null)

  lifecycle {
    precondition {
      condition     = contains(keys(local.template_by_name), each.value)
      error_message = "No directory role found with display name '${each.value}'. The name must match a roleTemplate in the tenant exactly, e.g. 'Groups Administrator' or 'User Administrator'. Check with: az rest --method GET --url 'https://graph.microsoft.com/v1.0/directoryRoleTemplates?$select=id,displayName'"
    }
  }
}

# ------------------------------------------------------------------------------
# 2) Groups
#
# assignable_to_role is hardcoded true. Entra requires a group to be
# role-assignable in order to carry a directory role, so it is not a choice.
#
# WARNING: the attribute is force-replace. The group cannot be made
# role-assignable after the fact — it must be recreated. This is why M4 groups
# can never be reused from M2/M3 and vice versa. See risk R3.
# ------------------------------------------------------------------------------

module "groups" {
  source = "../entra-groups"

  groups = {
    for role_key, role in var.roles : role_key => {
      name        = local.group_names[role_key]
      description = local.group_descriptions[role_key]

      owner_user_principal_names = var.set_systemeier_as_group_owner ? var.systemeier : []

      # Membership comes from the access package in repo 2, never from here.
      member_user_principal_names = []

      assignable_to_role = true
    }
  }
}

# ------------------------------------------------------------------------------
# 3) Wait for Graph propagation
#
# A role binding against a group that has not had time to replicate fails. Same
# problem as in pim-for-groups.
# ------------------------------------------------------------------------------

resource "time_sleep" "group_propagation" {
  for_each = var.roles

  depends_on      = [module.groups]
  create_duration = var.propagation_delay

  triggers = {
    group_object_id = module.groups.group_object_ids[each.key]
  }
}

# ------------------------------------------------------------------------------
# 4a) Permanent role binding
#
# The role applies as long as the group membership lasts. Time-limiting then
# comes from the expiry on the access package assignment in repo 2, not from
# PIM.
# ------------------------------------------------------------------------------

resource "azuread_directory_role_assignment" "permanent" {
  for_each = {
    for role_key, role in var.roles : role_key => role
    if role.permanent_access
  }

  # template_id, not object_id. See the comment on local.template_by_name.
  role_id             = azuread_directory_role.this[each.value.entra_role].template_id
  principal_object_id = module.groups.group_object_ids[each.key]
  directory_scope_id  = var.directory_scope_id

  depends_on = [time_sleep.group_propagation]
}

# ------------------------------------------------------------------------------
# 4b) Eligible role binding
#
# The group becomes eligible for the role. Members activate it themselves in
# PIM.
#
# NOTE: the resource has no schedule block. Eligibility is permanent, and it is
# not optional — the provider exposes no expiry date. The lifecycle must be
# controlled by the access package assignment in repo 2.
# ------------------------------------------------------------------------------

resource "azuread_directory_role_eligibility_schedule_request" "this" {
  for_each = {
    for role_key, role in var.roles : role_key => role
    if !role.permanent_access
  }

  role_definition_id = azuread_directory_role.this[each.value.entra_role].template_id
  principal_id       = module.groups.group_object_ids[each.key]
  directory_scope_id = var.directory_scope_id
  justification      = each.value.eligible_justification

  depends_on = [time_sleep.group_propagation]
}
