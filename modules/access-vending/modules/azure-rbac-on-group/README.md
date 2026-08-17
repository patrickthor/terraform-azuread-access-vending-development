# Module: `azure-rbac-on-group`

Binds an Entra group to an Azure RBAC role on a given scope. **This is the only
Azure-specific module in the repo.** Parallel modules for other clouds:
`aws-permission-set-on-group`, `gcp-iam-on-group`, `github-team-role-on-group`.

## The model

The module has two modes per assignment, controlled by `permanent_access`:

| `permanent_access` | Resources | User experience |
|---|---|---|
| `false` *(default)* | `azurerm_pim_eligible_role_assignment` + `azurerm_role_management_policy` | Must activate the role. MFA, approval, and duration per policy. |
| `true` | `azurerm_role_assignment` | Access as long as the principal is a member of the group. |

This is **PIM for Azure Resources** — just-in-time is in the *role*. The groups
used here are not PIM-managed as groups; membership is active and comes from the
access package in repo 2.

For `permanent_access = true`, the time limit comes from expiry on the access
package assignment, not from RBAC.

## Input

| Name | Type | Default | Description |
|---|---|---|---|
| `assignments` | `map(object)` | `{}` | Assignments, keyed on a stable identifier. |

Fields per assignment:

| Field | Type | Default | Description |
|---|---|---|---|
| `principal_object_id` | `string` | — | Entra object ID of the group. |
| `role_definition_name` | `string` | — | Azure RBAC role name. Free string. |
| `scope` | `string` | — | ARM scope, e.g. `/subscriptions/{id}`. |
| `description` | `string` | `null` | Description. Used as `justification` on eligible assignments. |
| `permanent_access` | `bool` | `false` | `true` gives a permanent binding. |
| `max_activation_hours` | `number` | `8` | 1–23. |
| `require_approval` | `bool` | `true` | Approval on activation. |
| `require_mfa` | `bool` | `false` | MFA on activation. |
| `require_justification` | `bool` | `true` | Justification on activation. |
| `require_ticket_info` | `bool` | `false` | Ticket number on activation. |
| `approvers` | `list(object)` | `[]` | `{ object_id, type }`. `type` must be `"User"` or `"Group"`. |
| `eligible_duration_days` | `number` | `null` | `null` gives permanent eligibility. |

Fields from `max_activation_hours` and below have no effect when
`permanent_access = true`.

## Output

| Name | Description |
|---|---|
| `access_model` | `"permanent"` or `"eligible"` per key. |
| `scopes` | Scope per key. |
| `role_definition_ids` | Looked-up `role_definition_id` per key. |
| `permanent_role_assignment_ids` | Resource ID per permanent binding. |
| `eligible_role_assignment_ids` | Resource ID per eligible binding. |
| `activation_policy_ids` | Policy ID per `"{scope}\|{role}"`. |
| `effective_activation_settings` | Effective activation rules per eligible key. |

## Call example

```hcl
module "rbac" {
  source = "../azure-rbac-on-group"

  assignments = {
    "reader" = {
      principal_object_id  = module.groups.group_object_ids["reader"]
      role_definition_name = "Reader"
      scope                = "/subscriptions/${var.subscription_id}"
      permanent_access     = true
    }

    "owner" = {
      principal_object_id  = module.groups.group_object_ids["owner"]
      role_definition_name = "Owner"
      scope                = "/subscriptions/${var.subscription_id}"
      permanent_access     = false
      max_activation_hours = 2
      require_mfa          = true
      require_approval     = true

      approvers = [
        { object_id = data.azuread_user.systemeier["ola@kunde.no"].object_id, type = "User" },
        { object_id = data.azuread_group.team.object_id, type = "Group" },
      ]
    }
  }
}
```

## Design choices and limitations worth knowing

**Deterministic `name` on permanent bindings.** Without an explicit `name`,
Azure generates a random GUID server-side, and formatting differences in scope
or principal can cause false replace-on-drift. `uuidv5` makes the name a pure
function of (scope, role, principal). `azurerm_pim_eligible_role_assignment` has
no `name`, so this approach is not available there.

**`role_definition_name` is looked up to an ID.** Both
`azurerm_pim_eligible_role_assignment` and `azurerm_role_management_policy` require
`role_definition_id`, not role name. The module uses
`data "azurerm_role_definition"` and deduplicates the lookup on (scope, role name).

**The activation policy is keyed on (scope, role) — not per group.** Verified
against the provider schema. The policy applies to all principals with that role
on that scope. With one group per (subscription, role) this is 1:1 in practice,
but two eligible assignments with the same role on the same scope will collide.
A validation catches this.

**Only ONE `approval_stage` is allowed.** Also verified against the schema.
Multiple approvers in the same stage means one of them must sign. Real two-step
approval exists only on the access package request in repo 2.

**`approvers[*].type` uses `"User"` and `"Group"`.** These are different values
than the `azuread` provider, which uses `singleUser` and `groupMembers`. A
validation catches the wrong value.

**The policy is auto-imported.** Azure creates the activation policy automatically;
the provider imports it on first use instead of creating it. Terraform thus takes
ownership — do not modify it manually in the portal afterwards, as that causes
drift. `notification_rules` is in `ignore_changes` because Azure fills in
defaults there.
