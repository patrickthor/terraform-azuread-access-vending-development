# Module: `pim-group-access`

Composite for **M3**: wraps `entra-groups` and `pim-for-groups` so the call
becomes one module block per scope.

Used for AWS, GCP, and GitHub, where there is no role-level JIT to activate.
Access in the target cloud is permanently tied to the group, so it is the
**membership** that must be just-in-time.

## Difference from `azure-subscription-access`

| | `azure-subscription-access` (M2) | `pim-group-access` (M3) |
|---|---|---|
| Group is PIM-managed | no | **yes** |
| JIT is in | the **role** | the **membership** |
| Mechanism | PIM for Azure Resources | PIM for Groups |
| `access_type` in repo 2 | `Member` | `EligibleMember` |
| Providers | `azuread` + `azurerm` | `azuread` + `time` |
| Authorization created by Terraform | yes, Azure RBAC | **no**, see below |
| Risk R1 applies | no | **yes** |

## What it does not do

**The module does not connect the group to anything in the target cloud.** It
creates the group and the activation rules. The actual authorization — AWS
permission set assignment, GCP IAM binding, GitHub team membership — happens on
the cloud side, and the group must be provisioned there with SCIM from the
enterprise application in Entra.

That is outside this repo. `target_role` and `scope_id` exist to document what
the binding should be. The output `target_cloud_bindings` is the work list:

```bash
terraform output target_cloud_bindings
```

The consequence is worth noting: until that binding is set up, the group grants
no actual access. Activation will appear to work in PIM, without anything
happening in AWS.

## What it does

For each role in `roles`:

1. Creates an Entra group named `{cloud_prefix}-{scope_key}-{role}` — same
   naming contract as M2.
2. Sets PIM for Groups activation policy on the group, with approval, MFA,
   duration, and justification per the fields below.

No members are set, and in normal operation no eligible members either: the
access package in repo 2 grants `EligibleMember`.

**One group = one role = one scope.**

## No `permanent_access`

M2 has `permanent_access` because there is a meaningful choice there: the role
binding can be permanent while the group is still a regular group.

Here the choice does not exist. The entire mechanism is that membership is
time-limited. A "permanent" variant is a plain group without PIM — that is, not
this module. The root validation rejects `permanent_access = true` together with
`jit_mechanism = "pim_for_groups"` instead of silently ignoring it.

## Input

| Name | Type | Default | Description |
|---|---|---|---|
| `scope_key` | `string` | — | Short, stable key for the target. Becomes part of the group name. |
| `cloud_prefix` | `string` | — | `"aws"`, `"gcp"`, `"github"`. |
| `scope_id` | `string` | `""` | AWS account ID, GCP project ID, GitHub org. Documentation only. |
| `systemeier` | `list(string)` | — | UPNs, at least one. **All** become approvers when `approval_type` is `owner`/`dual`. |
| `approver_group_object_id` | `string` | `null` | Approver group for the scope. Created in the root module. Required when a role is `dual`. |
| `roles` | `map(object)` | — | Roles for this scope. |
| `group_description_template` | `string` | `null` | Placeholders `{cloud}`, `{sub}`, `{role}`, `{target_role}`, `{scope_id}`. `null` gives the module's own default. |
| `set_systemeier_as_group_owner` | `bool` | `false` | See warning below. |
| `propagation_delay` | `string` | `"30s"` | Wait time for Graph propagation. |

Fields per role:

| Field | Type | Default | Description |
|---|---|---|---|
| `target_role` | `string` | `""` | The role in the target cloud. Documentation only. |
| `approval_type` | `string` | `"owner"` | `self` \| `owner` \| `dual`. |
| `max_activation_hours` | `number` | `8` | 1–23. |
| `require_mfa` | `bool` | `false` | MFA on activation. |
| `require_justification` | `bool` | `true` | Justification on activation. |
| `require_ticket_info` | `bool` | `false` | Ticket number on activation. |
| `active_assignment_expire_after` | `string` | `"P30D"` | Cap on ACTIVE memberships. `null` allows permanent ones. |
| `eligible_assignment_expiration_required` | `bool` | `false` | Require expiration on eligibility. |
| `demo_eligible_user_principal_names` | `list(string)` | `[]` | Escape hatch, see below. |
| `assignable_to_role` | `bool` | `false` | Force-replace. See `entra-groups` README. |

### `max_activation_hours` vs `active_assignment_expire_after`

Two different things, easy to confuse:

- `max_activation_hours` — how long **one activation** lasts. After this the user
  drops out of the group.
- `active_assignment_expire_after` — the cap PIM enforces on an **active
  assignment** as such. If set to `null`, permanent active memberships are
  allowed, and the JIT guarantee disappears for those assignments.

### `demo_eligible_user_principal_names`

Gives a user standing eligibility directly, outside the access package flow.
Exists to allow demonstrating activation before repo 2 is in place.

The name is intentionally ugly. If there are values there in production, someone
got access outside the vending process. The output `demo_eligibility_schedules`
at root shows which ones are in use.

## Output

| Name | Description |
|---|---|
| `group_names` | Group name per role key. The contract toward repo 2. |
| `group_object_ids` | Entra object ID per role key. |
| `access_model` | Always `"eligible_member"`. |
| `access_package_access_type` | Always `"EligibleMember"`. For repo 2. |
| `activation_policy_ids` | PIM policy ID per role key. |
| `activation_settings` | Effective activation rules per role key. |
| `eligibility_schedule_ids` | Eligible assignments Terraform itself created. Normally empty. |
| `target_cloud_bindings` | The work list for the cloud side. |

## Call example

Normally called from root via `jit_mechanism`, not directly:

```hcl
module "pim_group_access" {
  source = "./modules/pim-group-access"

  scope_key    = "prod-konto"
  cloud_prefix = "aws"
  scope_id     = "419276583014"
  systemeier   = ["ola@kunde.no", "kari@kunde.no"]

  approver_group_object_id = module.approver_groups.group_object_ids["aws-prod"]

  roles = {
    "admin" = {
      target_role          = "AdministratorAccess"
      approval_type        = "owner"
      max_activation_hours = 8
      require_mfa          = true
    }

    "readonly" = {
      target_role          = "ReadOnlyAccess"
      approval_type        = "self"
      max_activation_hours = 4
    }
  }
}
```

## Approval logic

| `approval_type` | Approval | Approvers sent to the policy |
|---|---|---|
| `self` | off | none |
| `owner` | on | all `systemeier` as `singleUser` |
| `dual` | on, one stage | both, one of them signs |

**The `type` values are `singleUser` and `groupMembers`** — not `User` and
`Group`. `azuread` and `azurerm` use different values for the same concept. Do
not copy approver lists between this module and `azure-rbac-on-group` without
translating.

**`dual` degrades.** PIM for Groups allows only one `approval_stage`. Both
approvers are placed in the same stage, so one signature is enough. Real
two-step approval exists only on the access package request in repo 2. See
decision B3 in [the module README](../../README.md#beslutninger).

## `set_systemeier_as_group_owner` is `false` by design

Worse here than in M2. A group owner can add members directly, and a directly
added member is an **active** member — not eligible. This bypasses not only the
access package but the entire PIM activation with approval, MFA, and time
limitation.

## No collision validation — and why

M2 must validate that two eligible roles do not have the same `azure_role` on the
same scope, because `azurerm_role_management_policy` is keyed on `(scope, role)`.

Here `azuread_group_role_management_policy` is keyed on
`(group_id, assignment_type)`. With one group per role the key is unique by
definition, so the problem does not exist.

## Provider isolation

The module does **not** declare `azurerm`. This is an acceptance criterion — the
M3 path must be able to run without Azure Resource Manager at all. Verify:

```bash
cd modules/pim-group-access && terraform init -backend=false && terraform providers
# shall show hashicorp/azuread and hashicorp/time, not hashicorp/azurerm
```

## Inherited limitations

From `pim-for-groups`, and they apply fully here:

- **PIM management is irreversible.** A group cannot be removed from PIM
  management. Use disposable group names in the POC.
- **The policy is auto-imported.** Terraform takes ownership on first apply. Do
  not modify it manually in the portal afterwards.
- **Token propagation.** After activation, the group claim appears only on the
  next token issuance. Typically 5–10 minutes or sign-out/sign-in.
- **Risk R1 is unresolved.** Whether PIM actually onboards a regular security
  group as this module assumes has not been verified in the POC tenant. This is
  the M3 path's main risk. See [R1](../../README.md#risikoer) in the module
  README.
