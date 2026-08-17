# ==============================================================================
# entra-groups — cloud-agnostic security groups
#
# Creates cloud-only Entra security groups. No Azure-specific resources.
# The group is the primitive that is later bound to Azure RBAC, AWS permission
# sets, GCP IAM, or GitHub team roles.
# ==============================================================================

locals {
  # Flat map of (group, member) pairs for separate membership resources.
  member_pairs = merge([
    for group_key, group in var.groups : {
      for upn in group.member_user_principal_names :
      "${group_key}--${upn}" => {
        group_key = group_key
        upn       = upn
      }
    }
  ]...)

  all_upns = toset(concat(
    flatten([for g in values(var.groups) : g.owner_user_principal_names]),
    flatten([for g in values(var.groups) : g.member_user_principal_names]),
  ))
}

data "azuread_user" "principals" {
  for_each            = local.all_upns
  user_principal_name = each.value
}

resource "azuread_group" "this" {
  for_each = var.groups

  # display_name is the contract with the access-package repo.
  display_name = each.value.name

  # mail_nickname is set to the same string. It is unique within the tenant and
  # thus provides collision protection without changing the naming contract.
  mail_nickname = each.value.name

  description             = each.value.description != "" ? each.value.description : null
  security_enabled        = true
  assignable_to_role      = each.value.assignable_to_role
  prevent_duplicate_names = var.prevent_duplicate_names

  # Owners are managed here because neither access packages nor PIM modify them.
  # null (not an empty list) when none are specified: this lets Entra keep the
  # default setup it creates on its own, instead of attempting to empty the list.
  owners = length(each.value.owner_user_principal_names) > 0 ? [
    for upn in each.value.owner_user_principal_names :
    data.azuread_user.principals[upn].object_id
  ] : null

  # Membership is intentionally managed outside the group resource, via
  # azuread_group_member. Access packages and PIM activation add and remove
  # members outside Terraform; if we set members here, every plan would show
  # drift and attempt to remove them.
  lifecycle {
    ignore_changes = [
      members,
    ]
  }
}

resource "azuread_group_member" "this" {
  for_each = local.member_pairs

  group_object_id  = azuread_group.this[each.value.group_key].object_id
  member_object_id = data.azuread_user.principals[each.value.upn].object_id
}
