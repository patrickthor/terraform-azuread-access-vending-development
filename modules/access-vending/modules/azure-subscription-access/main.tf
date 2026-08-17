# ==============================================================================
# azure-subscription-access — composite for a single Azure subscription
#
# Wrapper for entra-groups + azure-rbac-on-group, so the LZ call becomes a
# single module block per subscription.
#
# NOTE: this module does NOT call pim-for-groups. Under M2 the Azure groups are
# not PIM-managed. Membership is active and comes from the access package in
# repo 2; just-in-time is in the ROLE via PIM for Azure Resources.
#
# pim-for-groups is used by the other clouds (M3), where JIT is in the
# membership because AWS, GCP, and GitHub have no role-level JIT to activate.
#
# Future sibling modules: aws-account-access, gcp-project-access,
# github-org-access.
# ==============================================================================

locals {
  subscription_scope = "/subscriptions/${var.subscription_id}"

  # Group name per role. This is the contract with the access-package repo.
  # Do not change without coordinating — repo 2 looks up this string.
  group_names = {
    for role_key in keys(var.roles) :
    role_key => "${var.cloud_prefix}-${var.subscription_key}-${role_key}"
  }

  # Same placeholder set as pim-group-access, so a single template in the root
  # works for both JIT mechanisms. {target_role} is the generic form — here it
  # is the Azure RBAC role.
  description_template = coalesce(
    var.group_description_template,
    "Access group for the role {role} ({target_role}) on subscription {sub}. Managed by Terraform."
  )

  group_descriptions = {
    for role_key, role in var.roles :
    role_key => replace(
      replace(
        replace(
          replace(
            replace(local.description_template, "{cloud}", var.cloud_prefix),
            "{sub}", var.subscription_key
          ),
          "{role}", role_key
        ),
        "{target_role}", role.azure_role
      ),
      "{scope_id}", var.subscription_id
    )
  }

  # Roles that require approval on activation. Permanent roles are never
  # activated, so they need no approvers.
  approval_roles = {
    for role_key, role in var.roles : role_key => role
    if !role.permanent_access && role.approval_type != "self"
  }

  # Do we need to look up the system owners? Yes if they are group owners, or
  # are approvers for at least one role. If the answer is no, no lookup is
  # performed — so the module does not require the UPNs to exist in the tenant.
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
  # Approvers per role, depending on approval_type:
  #
  #   "self"   none
  #   "owner"  the systemeier list, as named users
  #   "dual"   systemeier list + the scope's approver group, in the same stage
  #
  # The approver group is created in the root module, one per scope, because a
  # single scope can have roles across multiple mechanisms. The module receives
  # a ready-made object ID.
  #
  # NOTE: azurerm uses "User" and "Group" as type values. These are different
  # values from azuread, which uses singleUser and groupMembers. Verified
  # against the provider schema.
  #
  # PIM for Azure Resources has only ONE approval stage — also confirmed against
  # the schema: approval_stage has max_items = 1, while primary_approver is a
  # set without max. This has one consequence worth being explicit about:
  #
  #   All approvers — multiple system owners and the approver group with
  #   "dual" — end up in the SAME stage, and it is enough for ONE of them to
  #   sign.
  #
  # Multiple system owners therefore give broader coverage, not stricter
  # control. True sequential approval must live on the access package request in
  # repo 2. See decision B3.
  approvers_by_role = {
    for role_key, role in local.approval_roles : role_key => concat(
      role.approval_type == "dual" && var.approver_group_object_id != null ? [{
        object_id = var.approver_group_object_id
        type      = "Group"
      }] : [],
      contains(["owner", "dual"], role.approval_type) ? [
        for upn in sort(var.systemeier) : {
          object_id = data.azuread_user.systemeier[upn].object_id
          type      = "User"
        }
      ] : [],
    )
  }
}

# ------------------------------------------------------------------------------
# 1) Groups (cloud-agnostic)
#
# The groups are pure RBAC principals. No members are set here — they come from
# the access package in repo 2.
# ------------------------------------------------------------------------------

module "groups" {
  source = "../entra-groups"

  groups = {
    for role_key, role in var.roles : role_key => {
      name        = local.group_names[role_key]
      description = local.group_descriptions[role_key]

      owner_user_principal_names = var.set_systemeier_as_group_owner ? var.systemeier : []

      # Membership comes from the access package, never from here.
      member_user_principal_names = []

      assignable_to_role = role.assignable_to_role
    }
  }
}

# ------------------------------------------------------------------------------
# 2) Azure RBAC (Azure-specific)
#
# permanent_access = false gives an eligible assignment plus activation policy.
# permanent_access = true gives a permanent binding.
# ------------------------------------------------------------------------------

module "rbac" {
  source = "../azure-rbac-on-group"

  assignments = {
    for role_key, role in var.roles : role_key => {
      principal_object_id  = module.groups.group_object_ids[role_key]
      role_definition_name = role.azure_role
      scope                = local.subscription_scope

      description = role.permanent_access ? "Permanent ${role.azure_role} for ${local.group_names[role_key]} (Terraform)" : "JIT ${role.azure_role} for ${local.group_names[role_key]} (Terraform)"

      permanent_access = role.permanent_access

      max_activation_hours  = role.max_activation_hours
      require_approval      = role.approval_type != "self"
      require_mfa           = role.require_mfa
      require_justification = role.require_justification
      require_ticket_info   = role.require_ticket_info
      approvers             = lookup(local.approvers_by_role, role_key, [])

      eligible_duration_days = role.eligible_duration_days
    }
  }
}
