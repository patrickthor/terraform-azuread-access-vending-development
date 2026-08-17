# Module: `pim-for-groups`

> **Called by `pim-group-access` (M3), not by the Azure track (M2).**
>
> Under M2, the Azure groups are not PIM-managed — membership is active, and
> just-in-time is in the role via PIM for Azure Resources. See
> `azure-rbac-on-group`.
>
> This module belongs to **the other clouds** (M3): AWS, GCP, and GitHub have no
> role-level JIT to activate, so JIT must be in the group membership instead. The
> group is PIM-managed, the access package grants `EligibleMember`, and the user
> activates the membership.
>
> The module handles **one** group. `pim-group-access` does `for_each` over roles
> and calls it once per group. To use it from root, go via
> `jit_mechanism = "pim_for_groups"` in `access_scopes` instead of calling it
> directly.
>
> Risk R1 — whether PIM onboards regular security groups — therefore only applies
> to the M3 path, not the Azure track.

Sets PIM for Groups activation policy and eligible assignments on an existing
Entra group. **Cloud-agnostic** — uses `azuread` and `time`, not `azurerm`.

## The model

This is **PIM for Groups**, not PIM for Azure Resources:

1. The group has a permanent role assignment (Azure RBAC in this POC, later
   AWS permission set / GCP IAM / GitHub team role).
2. The user is an *eligible member* of the group, not an active member.
3. On activation, the user becomes an active member in a time-limited window,
   with MFA/approval/justification per policy.
4. When the window expires, membership is removed and access disappears.

## Input

| Name | Type | Default | Description |
|---|---|---|---|
| `group_object_id` | `string` | — | The group to be PIM-managed. |
| `assignment_type` | `string` | `"member"` | `"member"` or `"owner"`. |
| `maximum_activation_duration` | `string` | `"PT8H"` | ISO8601. PT30M–PT23H30M in 30-min steps, or PT1D. |
| `require_approval` | `bool` | `false` | Require approval on activation. |
| `primary_approvers` | `list(object)` | `[]` | `{ object_id, type }`. `type` = `singleUser` or `groupMembers`. |
| `require_multifactor_authentication` | `bool` | `false` | MFA on activation. |
| `require_justification` | `bool` | `true` | Justification required. |
| `require_ticket_info` | `bool` | `false` | Ticket number required. |
| `eligible_assignment_expiration_required` | `bool` | `false` | Whether eligibility must have an expiration. |
| `active_assignment_expire_after` | `string` | `"P30D"` | P15D/P30D/P90D/P180D/P365D or null. |
| `eligible_member_user_principal_names` | `list(string)` | `[]` | Eligible users, as UPN. |
| `eligible_permanent` | `bool` | `true` | Permanent eligibility. |
| `eligible_duration` | `string` | `null` | Duration when `eligible_permanent = false`. |
| `eligible_justification` | `string` | `"Assigned by Terraform..."` | Stored on the assignment. |
| `propagation_delay` | `string` | `"30s"` | Wait time for Graph propagation. |

## Output

| Name | Description |
|---|---|
| `policy_id` | ID of the activation policy. |
| `eligibility_schedule_ids` | ID per eligible assignment, keyed on UPN. |
| `eligible_principal_object_ids` | Object ID per eligible user. |
| `effective_activation_settings` | Summary for verification. |

## Call example

```hcl
module "pim" {
  source = "./modules/pim-for-groups"

  group_object_id             = module.groups.group_object_ids["contributor"]
  maximum_activation_duration = "PT8H"

  require_approval                   = true
  require_multifactor_authentication = true
  require_justification              = true

  primary_approvers = [
    {
      object_id = data.azuread_group.approvers.object_id
      type      = "groupMembers"
    },
  ]

  eligible_member_user_principal_names = ["kari@kunde.no"]
}
```

## Limitations and pitfalls

**Only one approval stage.** Entra/PIM for Groups has one approval round —
`activation_rules.approval_stage` exists in singular in the provider. Multiple
`primary_approvers` are in the same stage, and it is enough for one to sign.
Two-step ("dual") approval must be done on the access package request instead.
See decision 2 in [B3](../../README.md#beslutninger) in the module README.

**The policy is auto-imported.** Entra creates the policy automatically when the
group comes under PIM management; the provider imports it on first use. This has
two consequences: the first apply can fail with "not found" if the group has not
propagated (hence `propagation_delay`), and Terraform takes ownership — do not
modify the policy manually in the portal afterwards.

**PIM management is irreversible.** Once a group is under PIM management, it
cannot be removed. Use disposable group names in the POC.

**`notification_rules` is ignored.** Entra fills in defaults. Without
`ignore_changes`, every plan shows drift. To control notifications, the block
must be added explicitly and `ignore_changes` must be removed.

**Token propagation on activation.** After activation, existing tokens are not
updated. The group claim appears only on the next token issuance: the portal
typically requires 5–10 minutes or sign-out/sign-in, the CLI requires
re-authentication. This is Entra behavior, not a bug in the module.
