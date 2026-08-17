# Module: `azure-subscription-access`

Composite that wraps `entra-groups` and `azure-rbac-on-group` for one
subscription, so the LZ call becomes one module block per subscription.

The sibling module for the other clouds is `pim-group-access` (M3), which uses
PIM for Groups instead of Azure RBAC. The root module selects between them per
role with `jit_mechanism` — see "Why pim-for-groups is not used".

## What it does

For each role in `roles`:

1. Creates an Entra group named `{cloud_prefix}-{sub}-{role}`.
2. Binds the group to `azure_role` on subscription scope — permanent when
   `permanent_access = true`, otherwise eligible with an activation policy.

No members are set. They come from the access package in repo 2.

**One group = one role = one scope.** The naming convention has the role in the
name, so different access levels are given as different roles.

## Why `pim-for-groups` is not used

This module does **not** call `pim-for-groups`. The Azure groups are not
PIM-managed as groups: membership is active, and just-in-time is in the role via
PIM for Azure Resources.

`pim-for-groups` is used by the composite module `pim-group-access`, for the
other clouds, where JIT must be in the membership because AWS, GCP, and GitHub
have no role-level JIT to activate. See the mechanism table in
[`modules/access-vending/README.md`](../../README.md).

Practical consequence: risk R1 — whether PIM onboards regular security groups —
does not apply to the Azure track.

If you intentionally want to PIM-manage an Azure group instead, that option
exists: set `jit_mechanism = "pim_for_groups"` on the role. You then lose
role-level granularity and ABAC, which is why it is not the default for Azure.

## Input

| Name | Type | Default | Description |
|---|---|---|---|
| `subscription_key` | `string` | — | Short, stable key. Becomes part of the group name. |
| `subscription_id` | `string` | — | Azure subscription ID. |
| `systemeier` | `list(string)` | — | UPNs, at least one. **All** become approvers when `approval_type` is `owner`/`dual`. |
| `approver_group_object_id` | `string` | `null` | Approver group for the scope. Created in the root module. Required when a role is `dual`. |
| `roles` | `map(object)` | — | Roles for the subscription. |
| `cloud_prefix` | `string` | `"azure"` | Prefix on group names. |
| `group_description_template` | `string` | `null` | Placeholders `{cloud}`, `{sub}`, `{role}`, `{target_role}`, `{scope_id}`. `null` gives the module's own default. |
| `set_systemeier_as_group_owner` | `bool` | `false` | See warning below. |

Fields per role:

| Field | Type | Default | Description |
|---|---|---|---|
| `azure_role` | `string` | — | Azure RBAC role name. Free string. |
| `permanent_access` | `bool` | `false` | `true` gives a permanent binding instead of eligible. |
| `approval_type` | `string` | `"owner"` | `self` \| `owner` \| `dual`. |
| `max_activation_hours` | `number` | `8` | 1–23. |
| `require_mfa` | `bool` | `false` | MFA on activation. |
| `require_justification` | `bool` | `true` | Justification on activation. |
| `require_ticket_info` | `bool` | `false` | Ticket number on activation. |
| `eligible_duration_days` | `number` | `null` | `null` gives permanent eligibility. |
| `assignable_to_role` | `bool` | `false` | Force-replace. See `entra-groups` README. |

Everything from `approval_type` and below has no effect when `permanent_access = true`.

## Output

| Name | Description |
|---|---|
| `group_names` | Group name per role key. The contract toward repo 2. |
| `group_object_ids` | Entra object ID per role key. |
| `access_model` | `"permanent"` or `"eligible"` per role key. |
| `role_assignment_scopes` | Scope per role key. |
| `permanent_role_assignment_ids` | Resource ID per permanent binding. |
| `eligible_role_assignment_ids` | Resource ID per eligible binding. |
| `activation_policy_ids` | Policy ID per `"{scope}\|{role}"`. |
| `activation_settings` | Effective activation rules per eligible role key. |
| `subscription_scope` | The scope string that was used. |

## Call example

```hcl
module "subscription_access" {
  source = "./modules/azure-subscription-access"

  subscription_key = "sub-alpha"
  subscription_id  = var.subscription_id
  systemeier       = ["ola@kunde.no", "kari@kunde.no"]

  approver_group_object_id = module.approver_groups.group_object_ids["sub-alpha"]

  roles = {
    "reader" = {
      azure_role       = "Reader"
      permanent_access = true
    }

    "owner" = {
      azure_role           = "Owner"
      permanent_access     = false
      approval_type        = "dual"
      max_activation_hours = 2
      require_mfa          = true
    }
  }
}
```

## Approval logic

| `approval_type` | Approval | Approvers sent to the policy |
|---|---|---|
| `self` | off | none |
| `owner` | on | all `systemeier` as `User` |
| `dual` | on, one stage | both, one of them signs |

The `type` values are `"User"` and `"Group"` because `azurerm` uses different
values than `azuread`, which has `singleUser` and `groupMembers`.

**`dual` degrades.** PIM for Azure Resources allows only one `approval_stage` —
verified against the provider schema. Both approvers are placed in the same
stage, so one signature is enough. Real two-step approval exists only on the
access package request in repo 2. See decision B3 in
["Decisions"](../../README.md#beslutninger) in the module README.

## `set_systemeier_as_group_owner` is `false` by design

A group owner can manage membership directly and thereby bypass the access
package entirely. Combined with the fact that membership is managed outside
Terraform, such a bypass would never be flagged in a plan.

The systemeier does not need to be an owner to be an approver — those are two
independent mechanisms in this module.

## Role names are never hardcoded

`roles` is a map with arbitrary keys, and `azure_role` is a free string. No code
in this module or its submodules special-cases role names.
`reader`/`contributor`/`owner` are examples in the documentation, not values the
code recognizes.

## Limitation: one role per group, subscription scope

The naming convention `{cloud_prefix}-{sub}-{role}` has no room for scope, so
the module always binds at the subscription level. If someone needs access to
only one resource group, the convention cannot express it — that must be solved
by extending the convention or outside this module.

If a job function needs multiple roles simultaneously, that is bundled in the
**access package layer** in repo 2, not by adding multiple roles to one group.
