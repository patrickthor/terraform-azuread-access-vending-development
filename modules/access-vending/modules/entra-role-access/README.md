# Module: `entra-role-access`

Composite for **M4**: binds Entra groups to directory roles — Groups
Administrator, User Administrator, Directory Readers, and the other 145 role
templates in the tenant.

Called from root via `jit_mechanism = "entra_role"`.

## Read this first

**Terraform cannot set the activation rules for directory roles.**

The `azuread` provider has no policy resource for them.
`azuread_group_role_management_policy` takes `group_id` and applies to *groups*;
there is no `azuread_directory_role_management_policy`. The consequence is that
MFA, approval, max activation duration, and justification requirements for an
eligible directory role must be set in the PIM portal, and Terraform neither
reads nor enforces them.

Therefore the root module **rejects** `approval_type`,
`max_activation_hours`, `require_mfa`, `require_justification`, and
`require_ticket_info` for `entra_role` roles. Accepting them and ignoring them
would be a security lie: someone writes `require_mfa = true`, sees the plan is
green, and believes MFA is required.

The gap is visible in the output, not just here:

```bash
terraform output entra_activation_governance_gap
```

## Placement among the three mechanisms

| | M2 `azure-subscription-access` | M3 `pim-group-access` | M4 this one |
|---|---|---|---|
| Plane | Azure RBAC (ARM) | target cloud IAM | Entra directory |
| JIT is in | the role | the membership | the role |
| Group is PIM-managed | no | yes | no |
| Terraform sets activation rules | **yes** | **yes** | **no** |
| `assignable_to_role` | false | false | **always true** |
| `access_type` in repo 2 | `Member` | `EligibleMember` | `Member` |
| Providers | `azuread` + `azurerm` | `azuread` + `time` | `azuread` + `time` |

## What the module does

Per role in `roles`:

1. Looks up `entra_role` against `directoryRoleTemplates` to find the template ID.
2. Activates the directory role in the tenant if it is not already active. Most
   tenants have only a handful activated.
3. Creates a **role-assignable** group `{cloud}-{scope}-{role}`.
4. Waits for Graph propagation.
5. Binds the group to the role — permanent or eligible.

No members are set. Membership comes from the access package in repo 2.

## Template ID vs object ID

The most common mistake against this API. An activated directory role has **two**
identifiers, and they are always different:

```
Groups Administrator
  template_id  fdd7a751-b60b-444a-984c-02652fe8fa1c   <- roleDefinitionId wants this
  object_id    <annen guid>                            <- directoryRole object
```

`role_definition_id` and `role_id` want the **template ID**. If you use the
object ID you get a 400 from Graph. The module fetches the template ID from
`data.azuread_directory_role_templates`, where the field is called `object_id` —
that is the template object's own ID, not the activated role's.

Both are exposed as outputs (`directory_role_template_ids`,
`directory_role_object_ids`) precisely because the mix-up is easy.

## Input

| Name | Type | Default | Description |
|---|---|---|---|
| `scope_key` | `string` | — | Becomes part of the group name. `"tenant"` is natural for the entire tenant. |
| `cloud_prefix` | `string` | `"entra"` | Root validates that it is `"entra"`. |
| `directory_scope_id` | `string` | `"/"` | `"/"` or `"/administrativeUnits/<guid>"`. |
| `systemeier` | `list(string)` | — | UPNs, at least one. Used only if `set_systemeier_as_group_owner` is true. **Not** approvers here. |
| `roles` | `map(object)` | — | See below. |
| `group_description_template` | `string` | `null` | Placeholders `{cloud}`, `{sub}`, `{role}`, `{target_role}`, `{scope_id}`. |
| `set_systemeier_as_group_owner` | `bool` | `false` | See warning below. |
| `propagation_delay` | `string` | `"30s"` | Wait time before role binding. |

Fields per role:

| Field | Type | Default | Description |
|---|---|---|---|
| `entra_role` | `string` | **required** | Display name, e.g. `"Groups Administrator"`. Must match exactly. |
| `permanent_access` | `bool` | `false` | `true` gives a permanent binding, `false` gives eligible. |
| `eligible_justification` | `string` | `"Created by access vending (Terraform)"` | Graph requires a non-empty field. |

Note what is *not* here: no `approval_type`, no `require_mfa`, no
`max_activation_hours`. See the section at the top.

## Eligibility cannot have an expiration date

`azuread_directory_role_eligibility_schedule_request` has no `schedule` block.
Eligibility is permanent, and this is not optional — the provider exposes no
expiration date. The lifecycle must therefore be controlled by expiry on the
access package assignment in repo 2.

This differs from M2, where `eligible_duration_days` exists.

## Output

| Name | Description |
|---|---|
| `group_names` | Group name per role key. The contract toward repo 2. |
| `group_object_ids` | Entra object ID per role key. |
| `access_model` | `"permanent"` or `"eligible"`. |
| `access_package_access_type` | Always `"Member"`. |
| `directory_role_template_ids` | Template ID per role key. |
| `directory_role_object_ids` | Object ID for activated role per role key. |
| `directory_scope_id` | The scope the bindings are set on. |
| `permanent_role_assignment_ids` | Resource ID per permanent binding. |
| `eligibility_request_ids` | Resource ID per eligible binding. |
| `activation_governance_gap` | What Terraform does not control. |

## Call example

Normally via root, not directly:

```hcl
module "entra_role_access" {
  source = "./modules/entra-role-access"

  scope_key          = "tenant"
  cloud_prefix       = "entra"
  directory_scope_id = "/"
  systemeier         = ["ola@kunde.no"]

  roles = {
    "groupsadmin" = {
      entra_role = "Groups Administrator"
    }

    "directoryreader" = {
      entra_role       = "Directory Readers"
      permanent_access = true
    }
  }
}
```

Produces `entra-tenant-groupsadmin` and `entra-tenant-directoryreader`.

## `assignable_to_role` is hardcoded true — and it is irreversible

Entra requires that a group is role-assignable to carry a directory role, so the
module sets it without asking.

The attribute is **force-replace**. Practical consequences:

- An existing M2 or M3 group cannot be reused for M4. It must be recreated,
  which tears down all role bindings and leaves repo 2 pointing to an object ID
  that no longer exists.
- If you switch a role from `entra_role` to another mechanism, or vice versa,
  the group is deleted and recreated.

This is [R3](../../README.md#risikoer), and it hits harder here than in M2/M3
where the attribute is `false` and stays that way.

## `set_systemeier_as_group_owner` is `false` by design

More serious here than in the other modules. An owner of a role-assignable group
can add members directly. For a **permanent** binding they thereby get the
directory role immediately, without an access package and without PIM activation.

## Graph permissions

Beyond what M2 and M3 need:

```
RoleManagement.ReadWrite.Directory
RoleEligibilitySchedule.ReadWrite.Directory
```

`bootstrap/grant-graph-permissions.sh` covers them. Note that
`RoleManagement.ReadWrite.Directory` lets the service principal assign directory
roles across the entire tenant — only take it if you actually use M4.

As with M3, this cannot be run with `az login` as a user: the Azure CLI's
first-party app is not pre-authorized for these scopes.

## Provider isolation

No `azurerm`. Directory roles live in Graph, and there is no subscription
involved. Verify:

```bash
cd modules/entra-role-access && terraform init -backend=false && terraform providers
# shall show hashicorp/azuread and hashicorp/time, not hashicorp/azurerm
```

## Unresolved

- **Administrative units are not tested.** `directory_scope_id` accepts
  `/administrativeUnits/<guid>`, but not all directory roles can be scoped this
  way. Graph rejects the combination at apply, not at plan.
- **No drift detection on activation rules.** If someone changes the MFA
  requirement in the portal, Terraform sees nothing.
