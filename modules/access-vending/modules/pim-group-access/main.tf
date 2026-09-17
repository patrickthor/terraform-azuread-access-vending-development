# ==============================================================================
# pim-group-access — composite for M3 (PIM for Groups)
#
# Wrapper for entra-groups + pim-for-groups. Used for AWS, GCP, and GitHub,
# where there is no role-level JIT to activate: access in the target cloud is
# permanently bound to the group, so the MEMBERSHIP must be just-in-time.
#
# Difference from azure-subscription-access (M2):
#
#   M2  the group is NOT PIM-managed. Membership is active from the access
#       package. JIT is in the ROLE, via PIM for Azure Resources.
#   M3  the group IS PIM-managed. The access package grants EligibleMember, and
#       the user activates into the group. JIT is in the MEMBERSHIP.
#
# WHAT THIS MODULE DOES NOT DO: it does not bind the group to anything in the
# target cloud. It creates the group and the activation rules. The actual
# authorization — AWS permission set assignment, GCP IAM binding, GitHub team
# membership — happens on the cloud side, and the group must be provisioned
# there via SCIM from the enterprise application in Entra. That is outside this
# repo. `target_role` and `scope_id` exist to document what the binding SHOULD
# be.
# ==============================================================================

locals {
  # Group name per role. Same naming contract as M2 — repo 2 looks up this
  # string, so it must not be changed without coordination.
  group_names = {
    for role_key in keys(var.roles) :
    role_key => "${var.cloud_prefix}-${var.scope_key}-${role_key}"
  }

  # Eligibility-carrier name per role: the PIM group's name plus "-eligible".
  #
  # Part of the naming contract, so repo 2 can look it up by name the same way it
  # looks up the others. The root reserves role keys ending in "-eligible" so a
  # role cannot generate a name that collides with another role's carrier.
  carrier_suffix = "-eligible"

  carrier_group_names = {
    for role_key in keys(var.roles) :
    role_key => "${local.group_names[role_key]}${local.carrier_suffix}"
  }

  description_template = coalesce(
    var.group_description_template,
    "Access group for the role {role} ({target_role}) on {cloud} scope {sub}. PIM-managed membership. Managed by Terraform."
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
        "{target_role}", role.target_role
      ),
      "{scope_id}", var.scope_id
    )
  }

  # Roles that require approval on activation.
  approval_roles = {
    for role_key, role in var.roles : role_key => role
    if role.approval_type != "self"
  }

  needs_systemeier_lookup = var.set_systemeier_as_group_owner || anytrue([
    for role in values(local.approval_roles) :
    contains(["owner", "dual"], role.approval_type)
  ])

  systemeier_upns = local.needs_systemeier_lookup ? toset(var.systemeier) : toset([])
}

# ------------------------------------------------------------------------------
# Approver lookup
# ------------------------------------------------------------------------------

data "azuread_user" "systemeier" {
  for_each            = local.systemeier_upns
  user_principal_name = each.value
}

locals {
  # Approvers per role:
  #
  #   "self"   none
  #   "owner"  the systemeier list, as named users
  #   "dual"   systemeier list + the scope's approver group, in the same stage
  #
  # The approver group is created in the root module, one per scope, because a
  # single scope can have roles across multiple mechanisms. The module receives
  # a ready-made object ID.
  #
  # NOTE ON TYPE VALUES: azuread uses "singleUser" and "groupMembers". These are
  # DIFFERENT values from azurerm, which uses "User" and "Group" in
  # azure-rbac-on-group. Same concept, two different APIs — do not copy between
  # modules without translating.
  #
  # PIM for Groups has only ONE approval stage — approval_stage has max_items
  # = 1, while primary_approver is a set without max. All approvers, multiple
  # system owners as well as the approver group, therefore end up in the SAME stage,
  # and it is enough for ONE of them to sign. Multiple system owners give
  # broader coverage, not stricter control. True sequential approval only exists
  # on the access package request in repo 2. See decision B3.
  approvers_by_role = {
    for role_key, role in local.approval_roles : role_key => concat(
      role.approval_type == "dual" && var.approver_group_object_id != null ? [{
        object_id = var.approver_group_object_id
        type      = "groupMembers"
      }] : [],
      contains(["owner", "dual"], role.approval_type) ? [
        for upn in sort(var.systemeier) : {
          object_id = data.azuread_user.systemeier[upn].object_id
          type      = "singleUser"
        }
      ] : [],
    )
  }
}

# ------------------------------------------------------------------------------
# 1) Groups (cloud-agnostic)
#
# No members are set here. In M3, eligible members are also not set here in
# normal operation — the access package in repo 2 grants EligibleMember.
# ------------------------------------------------------------------------------

module "groups" {
  source = "../entra-groups"

  groups = {
    for role_key, role in var.roles : role_key => {
      name        = local.group_names[role_key]
      description = local.group_descriptions[role_key]

      owner_user_principal_names = var.set_systemeier_as_group_owner ? var.systemeier : []

      # Active membership never comes from here.
      member_user_principal_names = []

      assignable_to_role = role.assignable_to_role
    }
  }
}

# ------------------------------------------------------------------------------
# 1b) Eligibility carrier groups — PLAIN, one per role
#
# WHY THESE EXIST. The azuread provider cannot set access_type =
# "EligibleMember" on an access package resource role, so an access package
# attached straight to the PIM-managed group above grants NOTHING: the role gets
# excluded and left as a manual portal step, and a user approved for the package
# receives no membership. Instead the package grants plain Member on this group,
# and this group is an eligible member of the PIM-managed one. Each member then
# activates their own membership there, with approval, MFA and duration intact.
#
# ############################################################################
# # THIS GROUP MUST CARRY NO ACCESS OF ITS OWN. EVER.                        #
# #                                                                          #
# # No Azure RBAC binding. No SCIM provisioning to the target cloud. No app  #
# # role assignment. No directory role. It is a pure eligibility carrier.    #
# #                                                                          #
# # Bind anything to it and every member holds STANDING access to the target #
# # cloud — PIM is bypassed completely, the plan looks clean, the portal     #
# # looks right, and nothing fails. That is the whole failure mode this      #
# # repo exists to prevent.                                                  #
# #                                                                          #
# # It is deliberately absent from the target_cloud_bindings output, which   #
# # is the SCIM work list. Do not add it there.                             #
# ############################################################################
#
# A SEPARATE module instance rather than extra keys in the map above, so that
# group_object_ids keeps meaning "the PIM-managed group" with no filtering, and a
# carrier key can never collide with a role key.
#
# Never role-assignable: it holds no directory role, and role-assignable groups
# cannot have active group members anyway. Never any members from here — that is
# the access package's job.
# ------------------------------------------------------------------------------

module "carrier_groups" {
  source = "../entra-groups"

  groups = {
    for role_key, role in var.roles : role_key => {
      name = local.carrier_group_names[role_key]

      description = "Eligibility carrier for ${local.group_names[role_key]}. Access packages grant Member HERE; members then activate their own membership in the PIM-managed group. Carries no access of its own — never bind RBAC, SCIM, app roles or directory roles to this group. Managed by Terraform."

      # No owners: an owner could add members directly, which is the one thing
      # that must go through the access package.
      owner_user_principal_names = []

      # Membership comes from the access package in repo 2, never from here.
      member_user_principal_names = []

      # Hardcoded false, NOT role.assignable_to_role. This group must never carry
      # a directory role.
      assignable_to_role = false
    }
  }
}

# ------------------------------------------------------------------------------
# 2) PIM for Groups — activation policy per group
#
# pim-for-groups handles ONE group, so for_each iterates over roles.
#
# Unlike M2, there is no collision risk here:
# azuread_group_role_management_policy is keyed on (group_id,
# assignment_type), and with one group per role the key is unique by definition.
# azurerm_role_management_policy in M2 is keyed on (scope, role) and can
# collide — hence the validation there, and hence none here.
# ------------------------------------------------------------------------------

module "pim" {
  source   = "../pim-for-groups"
  for_each = var.roles

  group_object_id = module.groups.group_object_ids[each.key]
  assignment_type = "member"

  maximum_activation_duration        = "PT${each.value.max_activation_hours}H"
  require_approval                   = each.value.approval_type != "self"
  primary_approvers                  = lookup(local.approvers_by_role, each.key, [])
  require_multifactor_authentication = each.value.require_mfa
  require_justification              = each.value.require_justification
  require_ticket_info                = each.value.require_ticket_info

  eligible_assignment_expiration_required = each.value.eligible_assignment_expiration_required
  active_assignment_expire_after          = each.value.active_assignment_expire_after

  # Normally empty. See demo_eligible_user_principal_names in variables.tf.
  eligible_member_user_principal_names = each.value.demo_eligible_user_principal_names

  # The structural eligibility carrier. This is NOT a replacement for the demo
  # hatch above — that stays as the escape hatch for direct per-user eligibility.
  # This is what the access package in repo 2 actually attaches to.
  # "carrier" is a static key so the receiver's for_each is plan-known; the object
  # ID inside is an apply-time value, which is fine.
  eligible_member_group_object_ids = {
    carrier = module.carrier_groups.group_object_ids[each.key]
  }

  # Eligibility does not expire on its own — the lifecycle is owned by the
  # access package assignment in repo 2.
  eligible_permanent = true

  propagation_delay = var.propagation_delay
}
