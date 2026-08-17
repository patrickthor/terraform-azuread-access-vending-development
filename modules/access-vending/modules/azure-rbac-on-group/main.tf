# ==============================================================================
# azure-rbac-on-group — Azure RBAC binding on an Entra group
#
# Azure-specific. This is the component that is swapped per cloud: AWS gets a
# permission set assignment, GCP gets an IAM binding, GitHub gets a team role.
#
# Two modes, controlled by permanent_access per assignment:
#
#   permanent_access = false   PIM for Azure Resources. The group is the
#     (default)                principal on an eligible assignment; the user
#                              activates the role. JIT is in the ROLE, not in
#                              the membership.
#
#   permanent_access = true    Permanent binding. Access as long as the
#                              principal is a member. Time-limiting comes from
#                              the expiry on the access package assignment in
#                              repo 2.
#
# NOTE: the groups used here are NOT PIM-managed as groups. Membership is
# active, and comes from the access package.
# ==============================================================================

locals {
  permanent = { for k, a in var.assignments : k => a if a.permanent_access }
  eligible  = { for k, a in var.assignments : k => a if !a.permanent_access }

  # Role definitions must be looked up because both pim_eligible_role_assignment
  # and role_management_policy require role_definition_id, not role name.
  # Deduplicated on (scope, role name) to avoid identical lookups.
  role_lookups = {
    for pair in distinct([
      for a in values(var.assignments) : {
        key   = "${a.scope}|${a.role_definition_name}"
        scope = a.scope
        name  = a.role_definition_name
      }
    ]) : pair.key => pair
  }

  # Activation policy per (scope, role). The key is the same one Azure uses,
  # and variable validation guarantees it is unique among eligible assignments —
  # so the lookup is unambiguous.
  activation_policies = {
    for k, a in local.eligible :
    "${a.scope}|${a.role_definition_name}" => a
  }
}

data "azurerm_role_definition" "this" {
  for_each = local.role_lookups

  name  = each.value.name
  scope = each.value.scope
}

# ------------------------------------------------------------------------------
# 1) Permanent binding — permanent_access = true
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "permanent" {
  for_each = local.permanent

  # Deterministic name. Without this, Azure generates a random GUID server-side,
  # and subtle differences in formatting of scope or principal can cause false
  # replace-on-drift. uuidv5 makes the name a pure function of (scope, role,
  # principal).
  #
  # NOTE: name is ForceNew. If scope, role, or principal changes, the binding is
  # replaced. That is correct behavior — it IS a different binding.
  name = uuidv5("url", "${each.value.scope}|${each.value.role_definition_name}|${each.value.principal_object_id}")

  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  principal_id         = each.value.principal_object_id
  description          = each.value.description

  # The group is always the principal type here. Setting it explicitly skips
  # Azure's lookup against Entra, which can otherwise fail on newly created
  # groups that have not yet propagated.
  principal_type = "Group"
}

# ------------------------------------------------------------------------------
# 2) Activation policy — permanent_access = false
#
# The policy is keyed on (scope, role) and applies to ALL principals with that
# role on that scope, not just our group. With one group per (subscription, role)
# it is effectively 1:1, but worth knowing.
#
# Entra creates the policy automatically; the provider imports it on first use
# rather than creating it. Terraform thus takes ownership — do not modify it
# manually in the portal afterward.
# ------------------------------------------------------------------------------
resource "azurerm_role_management_policy" "activation" {
  for_each = local.activation_policies

  scope              = each.value.scope
  role_definition_id = data.azurerm_role_definition.this["${each.value.scope}|${each.value.role_definition_name}"].id

  activation_rules {
    maximum_duration                   = "PT${each.value.max_activation_hours}H"
    require_approval                   = each.value.require_approval
    require_justification              = each.value.require_justification
    require_multifactor_authentication = each.value.require_mfa
    require_ticket_info                = each.value.require_ticket_info

    # Only ONE approval_stage is allowed — confirmed against the provider schema.
    # Multiple approvers in the same stage means one of them must sign. True
    # two-stage approval only exists on the access package request in repo 2.
    dynamic "approval_stage" {
      for_each = each.value.require_approval ? [1] : []

      content {
        dynamic "primary_approver" {
          for_each = each.value.approvers

          content {
            object_id = primary_approver.value.object_id
            type      = primary_approver.value.type
          }
        }
      }
    }
  }

  # Rules for the eligible ASSIGNMENT itself, as opposed to activation above.
  #
  # Without this block the policy inherits the tenant default, which REQUIRES an
  # expiry date on eligible assignments. When eligible_duration_days is null the
  # module requests permanent eligibility, and Azure then rejects the request
  # with:
  #
  #   RoleAssignmentRequestPolicyValidationFailed: ExpirationRule -
  #   The policy does not allow permanent assignment
  #
  # NOTE ON SCOPE: the policy applies to (scope, role) for ALL principals, not
  # just our group. expiration_required = false therefore allows permanent
  # eligibility for anyone with that role on that scope. This is intentional in
  # this design — the lifecycle is owned by the access package assignment in
  # repo 2 — but it is a real widening of what the policy allows. Set
  # eligible_duration_days if you prefer Azure to enforce expiry itself.
  eligible_assignment_rules {
    expiration_required = each.value.eligible_duration_days != null
    expire_after        = each.value.eligible_duration_days != null ? "P${each.value.eligible_duration_days}D" : null
  }

  lifecycle {
    # notification_rules are not set by the module. Azure fills in defaults, and
    # without ignore_changes every plan would show drift on them.
    ignore_changes = [
      notification_rules,
    ]
  }
}

# ------------------------------------------------------------------------------
# 3) Eligible assignment — permanent_access = false
#
# The group becomes eligible for the role. Members activate it themselves,
# within the rules the policy above sets.
#
# The resource has no name attribute, so the uuidv5 approach from the permanent
# variant is not available here.
# ------------------------------------------------------------------------------
resource "azurerm_pim_eligible_role_assignment" "this" {
  for_each = local.eligible

  scope              = each.value.scope
  role_definition_id = data.azurerm_role_definition.this["${each.value.scope}|${each.value.role_definition_name}"].id
  principal_id       = each.value.principal_object_id

  justification = each.value.description

  # Omitted entirely when eligible_duration_days is null, so eligibility becomes
  # permanent instead of inheriting a duration we did not request.
  dynamic "schedule" {
    for_each = each.value.eligible_duration_days != null ? [1] : []

    content {
      expiration {
        duration_days = each.value.eligible_duration_days
      }
    }
  }

  # The policy must exist before eligibility is assigned, otherwise Azure fails
  # with RoleAssignmentRequestPolicyValidationFailed.
  depends_on = [azurerm_role_management_policy.activation]
}
