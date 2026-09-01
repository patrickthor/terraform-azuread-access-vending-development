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

  # Eligibility does not expire on its own — the lifecycle is owned by the
  # access package assignment in repo 2.
  eligible_permanent = true

  propagation_delay = var.propagation_delay
}
