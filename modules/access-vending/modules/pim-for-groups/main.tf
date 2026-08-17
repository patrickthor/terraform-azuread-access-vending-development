# ==============================================================================
# pim-for-groups — PIM for Groups policy + eligible assignment
#
# Cloud-agnostic. Sets activation rules on an existing Entra group and makes
# users eligible to activate into it.
#
# NOTE: PIM for Groups, not PIM for Azure Resources. The group has a permanent
# role assignment (Azure RBAC / AWS permission set / GCP IAM); it is the
# *membership* that is just-in-time.
# ==============================================================================

locals {
  eligible_upns = toset(var.eligible_member_user_principal_names)
}

data "azuread_user" "eligible" {
  for_each            = local.eligible_upns
  user_principal_name = each.value
}

# Newly created groups are not immediately available to the PIM endpoints in
# Graph. Without this wait, the first apply sporadically fails with "not found".
resource "time_sleep" "group_propagation" {
  create_duration = var.propagation_delay

  triggers = {
    group_object_id = var.group_object_id
  }
}

# ------------------------------------------------------------------------------
# Activation policy
#
# The policy is created automatically by Entra when the group is brought under
# PIM management. The provider auto-imports it on first use rather than creating
# it. This means Terraform takes ownership — do not modify it manually in the
# portal afterward.
# ------------------------------------------------------------------------------
resource "azuread_group_role_management_policy" "this" {
  group_id = var.group_object_id
  role_id  = var.assignment_type

  activation_rules {
    maximum_duration                   = var.maximum_activation_duration
    require_approval                   = var.require_approval
    require_justification              = var.require_justification
    require_ticket_info                = var.require_ticket_info
    require_multifactor_authentication = var.require_multifactor_authentication

    # Only one approval_stage is available in Entra for PIM for Groups.
    # Multiple approvers in the same stage = one of them must sign.
    dynamic "approval_stage" {
      for_each = var.require_approval ? [1] : []

      content {
        dynamic "primary_approver" {
          for_each = var.primary_approvers

          content {
            object_id = primary_approver.value.object_id
            type      = primary_approver.value.type
          }
        }
      }
    }
  }

  eligible_assignment_rules {
    expiration_required = var.eligible_assignment_expiration_required
  }

  # expiration_required is set EXPLICITLY. The attribute is Optional+Computed, so
  # if left empty the tenant value would decide whether expire_after is enforced
  # at all — and the plan would show no difference between "enforced" and "not
  # enforced". With only expire_after set, P30D is a cap for those assignments
  # that choose to have expiry, not a requirement that they do.
  #
  # Same pattern as eligible_assignment_rules in azure-rbac-on-group.
  active_assignment_rules {
    expiration_required   = var.active_assignment_expire_after != "permanent"
    expire_after          = var.active_assignment_expire_after == "permanent" ? null : var.active_assignment_expire_after
    require_justification = var.require_justification
  }

  depends_on = [time_sleep.group_propagation]

  lifecycle {
    # notification_rules are not set by the module. Entra fills in defaults, and
    # without ignore_changes every plan would show drift on them.
    ignore_changes = [
      notification_rules,
    ]
  }
}

# ------------------------------------------------------------------------------
# Eligible assignments
#
# The user becomes an eligible member — not an active member. Activation happens
# in the MyAccess/PIM portal and grants time-limited active membership.
# ------------------------------------------------------------------------------
resource "azuread_privileged_access_group_eligibility_schedule" "this" {
  for_each = local.eligible_upns

  group_id        = var.group_object_id
  principal_id    = data.azuread_user.eligible[each.value].object_id
  assignment_type = var.assignment_type

  permanent_assignment = var.eligible_permanent
  duration             = var.eligible_permanent ? null : var.eligible_duration
  justification        = var.eligible_justification

  depends_on = [
    time_sleep.group_propagation,
    azuread_group_role_management_policy.this,
  ]
}
