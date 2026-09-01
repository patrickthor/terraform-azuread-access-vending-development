# access-vending

Terraform module that vends access through Entra groups. Creates the groups,
binds them to access, and sets the activation rules — but grants no humans
access. That is done by the access-package repo.

```hcl
module "access_vending" {
  source = "github.com/<org>/terraform-azuread-access-vending//modules/access-vending?ref=v1.0.0"

  access_scopes = {
    "platform-prod" = {
      cloud      = "azure"
      scope_id   = "<subscription-guid>"
      systemeier = ["ola@kunde.no", "kari@kunde.no"]

      roles = {
        "reader"      = { azure_role = "Reader", permanent_access = true }
        "contributor" = { azure_role = "Contributor", approval_type = "dual" }
      }
    }
  }
}
```

Providers are owned by the caller. The module has no `provider` blocks, which is
the requirement for it to be used with `count`, `for_each` and `depends_on`. See
[`examples/complete/providers.tf`](../../examples/complete/providers.tf).

**Requires Terraform >= 1.9.** Validations use cross-variable references.

---

## Three JIT mechanisms

Selected **per role** with `jit_mechanism`. This is the most important knob in
the module.

| | `azure_pim` (default) | `pim_for_groups` | `entra_role` |
| --- | --- | --- | --- |
| Platform | PIM for Azure Resources | PIM for Groups | PIM for Entra roles |
| For | Azure RBAC | AWS, GCP, GitHub | Entra directory roles |
| JIT resides in | **the role** | **the membership** | **the role** |
| Group PIM-managed | no | **yes** | no |
| `access_type` in repo 2 | `Member` | `EligibleMember` | `Member` |
| Terraform creates the authorization | yes, Azure RBAC | **no**, SCIM on the cloud side | yes, directory role |
| Terraform sets the activation rules | yes | yes | **no** |
| Providers | `azuread` + `azurerm` | `azuread` + `time` | `azuread` + `time` |

### `azure_pim` — JIT in the role

Membership in the group is **active**. The user activates **the role**. This means
one activation, not two — if you are eligible for a group that itself has an
eligible role binding, you must activate both.

`permanent_access = true` gives a permanent role binding instead. In that case,
the time limit comes from the expiry on the access package assignment.

Requires `cloud = "azure"`, `azure_role` and `scope_id` as a subscription GUID.

### `pim_for_groups` — JIT in the membership

The group **is** PIM-managed. The access package grants `EligibleMember`, and the
user activates the membership. Used for clouds that have no role-level JIT to
activate.

**Terraform does not connect the group to the target cloud.** The group must be
provisioned there with SCIM and bound to the role there. `target_role` documents
what the binding should be; the output `target_cloud_bindings` is the work list.

Note that SCIM deprovisioning happens in the regular incremental cycle, not
immediately. The cycle runs every 40 minutes, so an 8-hour membership can in the
worst case give up to 40 minutes of extra access after Entra has revoked the
membership.

### `entra_role` — JIT in the role, without control over activation

The group is made role-assignable and bound to a directory role.

**Terraform cannot set the activation rules.** The `azuread` provider has no
policy resource for directory roles — `azuread_group_role_management_policy`
applies to groups. MFA, approval and max duration must be set in the PIM portal.
Therefore `approval_type`, `max_activation_hours`, `require_mfa`,
`require_justification` and `require_ticket_info` are *rejected* here, rather
than being silently ignored. The gap is visible in
`terraform output entra_activation_governance_gap`. See R6 for implementation
alternatives.

Two more things that are not obvious:

- For Entra roles, active Privileged Role Administrator and Global
  Administrator become **default approvers** if approval is required and none are
  set. This is the opposite of `azure_pim` and `pim_for_groups`, which have no
  default approvers. "No approval from Terraform" therefore does not mean "open
  role" — it means "managed outside Terraform".
- The role you are vending has power over the other mechanisms.
  `Groups Administrator` can manage membership in all non-role-assignable
  groups — that is, in all `azure_pim` and `pim_for_groups` groups — and can
  overwrite their PIM policies. Choose the role with that in mind.

Requires `cloud = "entra"`. `scope_id` here is `directory_scope_id`: `"/"` for the
entire tenant, or `/administrativeUnits/<guid>`.

---

## One group = one role = one scope

The naming convention `{cloud}-{scope}-{role}` has the role in the name, so
different access levels are issued as different groups:

```
azure-{sub}-reader        → Reader      on /subscriptions/{id}
azure-{sub}-contributor   → Contributor on /subscriptions/{id}
aws-{account}-admin       → AdministratorAccess in the AWS account
entra-tenant-groupsadmin  → Groups Administrator in the tenant
```

The prefix comes from `cloud`, not from the scope key. Scope key `aws-prod` with
`cloud = "aws"` yields `aws-aws-prod-admin` — use `prod`.

**Scope key and role key ARE the resource identity.** They are `for_each` keys and
form part of the group name. If you rename one of them, the group is deleted and
recreated: memberships disappear, and the access-package repo points to an
object ID that no longer exists. The plan shows only the group, not the loss.

If a job function needs multiple roles simultaneously, bundle it in the access
package layer — not by putting multiple roles on one group.

---

## Approval follows a role, not a person

| `approval_type` | Approvers | Creates an approver group? |
| --- | --- | --- |
| `self` | none | no |
| `owner` (default) | the `systemeier` list, as named users | no |
| `dual` | the `systemeier` list **and** the approver group (one signature is enough) | **yes** |

### When an approver group is created

A scope gets **one** approver group, `{cloud}-{scope}-approvers`, if and only if
**at least one role under it uses `approval_type = "dual"`**. One `dual` role is
enough, and the group then serves every role in that scope.

Scopes where every role is `self` or `owner` get no group — `owner` names the
systemeier directly in the policy, so there is nothing for a group to do. Scopes
containing only `entra_role` roles never get one either, because Terraform cannot
write directory-role activation policy at all (see R6).

The group is **seeded with the `systemeier`** as members. That grants them nothing
new — they are already named approvers for `owner` and `dual` — but it guarantees
the group is never empty. Additional peer approvers should be vended through an
access package like all other access.

Owners are deliberately **not** set on the approver group. A group owner can
manage membership directly and could grant themselves approval authority; members
cannot.

### Read this before you test activation

The approver group is seeded with the `systemeier`, so a `dual` role is
activatable from the first apply. PIM has no default approvers for `azure_pim` or
`pim_for_groups`, and a request with no reachable approver times out after 24
hours. The approval window is not configurable.

**But one member is not enough to test with.** An approver cannot approve their
own request, so a lone systemeier cannot activate their own `dual` role — the
request will sit until it times out. Add at least one more approver, ideally via
an access package, before testing activation.

### `dual` does not mean two signatures

The provider schema allows only **one** `approval_stage` — verified in both
providers. All approvers therefore end up in the same stage, and it is enough for
**one** to sign, even with `dual`. More approvers gives broader coverage, not
stricter control. True sequential approval must reside on the access package
request.

The same applies to multiple `systemeier`: broader coverage, so that vacation does
not block activation.

### The service principal owns the groups

If no `owners` are specified on an `azuread_group`, Graph assigns ownership to the
calling principal and retains it. A group cannot exist without owners. The deploy
identity therefore appears as owner on all groups, and
`set_systemeier_as_group_owner = false` does not mean "no owners".

This is accepted by design: a service principal with `Group.ReadWrite.All` can
modify membership regardless, so the ownership grants it no new power. The
alternative would give *humans* standing ownership, and a group owner can add
members directly, thereby bypassing the access package — unseen, since `members`
is under `ignore_changes`.

**Consequence:** if you run apply from a user account instead of a service
principal, one human becomes the sole owner of all groups. Run apply as a service
principal.

An Entra group cannot be the owner of another group — `owners` accepts only
users and service principals. Therefore the approver group is an *approver*, not
an owner.

---

## Input

| Variable | Type | Default | Description |
| --- | --- | --- | --- |
| `access_scopes` | `map(object)` | `{}` | Scopes and roles. Field reference below. |
| `cloud_prefix` | `string` | `"azure"` | Default prefix when a scope does not set `cloud`. Only `[a-z0-9]`. |
| `group_description_template` | `string` | `null` | Placeholders `{cloud}`, `{sub}`, `{role}`, `{target_role}`, `{scope_id}`. |
| `set_systemeier_as_group_owner` | `bool` | `false` | See warning above. |
| `pim_group_propagation_delay` | `string` | `"30s"` | Wait time for Graph propagation. Applies to `pim_for_groups` **and** `entra_role`. |

### Field reference — `access_scopes`

#### Per scope

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `cloud` | `string` | `var.cloud_prefix` | Prefix in the group name. Must be `azure` for `azure_pim` scopes and `entra` for `entra_role` scopes. |
| `scope_id` | `string` | `null` | Subscription GUID for `azure_pim` (validated). `directory_scope_id` for `entra_role` (validated). Otherwise a free-form string for documentation. |
| `systemeier` | `list(string)` | required | UPNs, at least one, no duplicates. All become approvers for `owner` and `dual`. |
| `approver_group_name` | `string` | `null` | `null` = the module creates `{cloud}-{scope}-approvers`. If set, the group is looked up and must already exist. |
| `roles` | `map(object)` | required | See below. |

#### Per role — common

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `jit_mechanism` | `string` | `"azure_pim"` | `azure_pim`, `pim_for_groups` or `entra_role`. |
| `permanent_access` | `bool` | `false` | `azure_pim` and `entra_role`. Rejected for `pim_for_groups`. |
| `assignable_to_role` | `bool` | `false` | **Force-replace.** Always `true` for `entra_role`, set by the module. |

#### Per role — activation rules

Applies to `azure_pim` and `pim_for_groups`. **Rejected for `entra_role`.**

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `approval_type` | `string` | `"owner"` | `self`, `owner`, `dual`. |
| `max_activation_hours` | `number` | `8` | 1–23. |
| `require_mfa` | `bool` | `false` | MFA on activation. |
| `require_justification` | `bool` | `true` | Justification on activation. |
| `require_ticket_info` | `bool` | `false` | Ticket number on activation. |

Defaults are set in the module's `main.tf`, not in the variable type. The fields
are `null` when unspecified — that is the only way to distinguish "not set" from
"set to the default value", and therefore the only way `entra_role` can reject
them.

#### Per role — `azure_pim` only

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `azure_role` | `string` | required | Azure RBAC role name. Free-form string. |
| `eligible_duration_days` | `number` | `null` | 15, 30, 90, 180, 365. `null` = permanent eligibility. |

`eligible_duration_days = null` loosens the policy for **all** principals on
(scope, role), not just for your group. This is the default behavior, and worth
knowing: you are loosening a tenant rule by omitting a field.

#### Per role — `pim_for_groups` only

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `target_role` | `string` | required | The role in the target cloud. Documentation only. |
| `active_assignment_expire_after` | `string` | `"P30D"` | `P15D`/`P30D`/`P90D`/`P180D`/`P365D`, or `"permanent"`. |
| `eligible_assignment_expiration_required` | `bool` | `false` | Require expiry on eligibility. |
| `demo_eligible_user_principal_names` | `list(string)` | `[]` | **Escape hatch.** See below. |

`active_assignment_expire_after = "permanent"` allows permanent active
memberships and removes the JIT guarantee for them. The sentinel is a **string**
and not `null`, by design: `optional()` and a variable's `default` both replace
explicit `null` with the default value, so a null-based sentinel disappears
silently through the module layers.

#### Per role — `entra_role` only

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `entra_role` | `string` | required | The role's `display_name`, e.g. `"Groups Administrator"`. |
| `eligible_justification` | `string` | `null` | Justification on the eligible request. Graph requires a non-empty value. |

`eligible_justification` is **ForceNew** in the provider. A cosmetic edit to the
text tears down and recreates the eligibility on the directory role.

### Fields belonging to one mechanism are rejected

Not ignored. An `azure_role` on a `pim_for_groups` role would never be used, and
the configuration would be lying about what the access provides. The same
principle applies to activation rules on `entra_role`: Terraform cannot enforce
them, so accepting them would be a security lie.

`demo_eligible_user_principal_names` gives a user standing eligibility **outside**
the access package flow. It exists to allow demonstrating activation before repo 2
is in place. If values remain there in production, someone has been granted access
outside the vending process — the output `demo_eligibility_schedules` shows which.

---

## Output

The contract toward the access-package repo is `group_names`,
`access_package_access_type` and `approver_group_names`.

| Output | Keyed on | Description |
| --- | --- | --- |
| `group_names` | composite | Group names. Repo 2 looks up by this string. |
| `group_object_ids` | composite | Entra object IDs. |
| `access_package_access_type` | composite | `Member` or `EligibleMember`. |
| `access_model` | composite | `permanent`, `eligible` or `eligible_member`. |
| `jit_mechanism` | composite | Which mechanism manages the role. |
| `permanent_roles` | list | Roles with permanent binding. |
| `jit_roles` | list | Roles that require activation. |
| `activation_settings` | composite | **Requested** activation rules, not effective. See warning below. |
| `approvers_by_role` | composite | Who approves what. |
| `approver_group_names` | **scope** | Approver group per scope. |
| `approver_group_object_ids` | **scope** | Object ID per approver group. |
| `approver_group_is_managed_here` | **scope** | `false` means the group lives outside the vending process. |
| `azure_role_assignment_scopes` | composite | ARM scope. `azure_pim` only. |
| `azure_activation_policy_ids` | scope | Policy ID per `{scope}\|{role}`. |
| `pim_group_policy_ids` | composite | `pim_for_groups` only. |
| `target_cloud_bindings` | composite | Work list for SCIM. `pim_for_groups` only. |
| `entra_role_template_ids` | composite | `roleDefinitionId`. `entra_role` only. |
| `entra_role_object_ids` | composite | The activated role's object ID. Always differs from the template ID. |
| `entra_activation_governance_gap` | composite | What Terraform does not manage for `entra_role`. |
| `demo_eligibility_schedules` | composite | Should be empty. |
| `access_summary` | list | One line per role, for reading the plan quickly. |

The composite key is `{scope}--{role}`. `--` is reserved and validated out of
both scope keys and role keys. The approver groups are keyed on **scope key**,
because one group approves all roles under the scope.

> `activation_settings` echoes the input; it does not read from the resource. All
> attributes in the policy blocks are `Optional+Computed`, so where the module does
> not set a value the tenant value wins without the plan reporting it. The output
> therefore confirms what was *requested*, not what is in effect. To see the
> actual values, read the policy from Graph or ARM.

---

## Risks

<a id="risikoer"></a>

**R1 — PIM onboarding of the group.** `pim_for_groups` assumes that PIM takes the
group under management. It does: PIM onboards automatically when the PIM policy is
written, and there is no explicit onboarding. The module writes the policy, so
`assignable_to_role` is **not** required for `pim_for_groups`.

**Onboarding is irreversible.** A group that is PIM-managed cannot be taken out of
management again. If the group is deleted, it can remain in the PIM list for up to
24 hours.

**R2 — Unmanaged policy attributes.** All attributes in the policy blocks are
`Optional+Computed`. The module can set a rule, never remove it, and where it does
not set anything the tenant value wins silently. Concretely unmanaged today:
`required_conditional_access_authentication_context` in both mechanisms, and the
entire `active_assignment_rules` in `azure_pim`.

**R3 — `assignable_to_role` is force-replace.** The attribute cannot be changed
after creation. The group is deleted and recreated, which tears down all role
bindings and leaves the access-package repo pointing to an object ID that no
longer exists.

The module sets it to `true` for `entra_role` because Entra requires it. The
consequence is that an existing `azure_pim` or `pim_for_groups` group **cannot**
be converted to an `entra_role` group. Place `entra_role` roles in a separate
scope.

Maximum 500 role-assignable groups per tenant. All members and owners of such
groups also become *protected users* — a Helpdesk Administrator can no longer
reset their password.

**R4 — Activation of a directory role cannot be reversed.**
`azuread_directory_role` does nothing on destroy. A `terraform destroy` leaves the
roles activated in the tenant.

**R5 — Token and claim propagation.** The three mechanisms behave differently:

- `pim_for_groups`: active membership in seconds, but the application may have
  cached the opposite. Logging out may be necessary.
- `azure_pim`: activation happens in seconds, but the ARM cache can cause up to 10
  minutes before the role binding takes effect.
- `entra_role`: same cache caveat.

**R6 — Activation rules for `entra_role` are not managed by Terraform.**
The `azuread` provider (v3.9.0, August 2026) has no
`azuread_directory_role_management_policy` resource. MFA requirements, approval
flows and maximum activation duration for directory roles therefore cannot be set,
read or drift-detected by Terraform.

The Graph API fully supports this via `PATCH
/policies/roleManagementPolicies/{id}/rules/{ruleId}` (v1.0, scopeType =
`DirectoryRole`). Three implementation alternatives have been evaluated for future
closure of this gap:

1. **`terraform_data` + `local-exec` with `az rest`** — simplest, but
   fire-and-forget: Terraform will not detect drift if someone changes the policy
   in the portal afterwards.
2. **`restapi` provider** — provides full CRUD and drift detection, but is a
   third-party provider.
3. **Wait for HashiCorp to add the resource** — the only path to true
   first-class Terraform support.

Until the gap is closed, the module rejects the activation fields for `entra_role`
rather than silently ignoring them. The output `entra_activation_governance_gap`
surfaces what is not managed. Activation rules must be set in the PIM portal or
via Graph manually.

---

## Decisions

<a id="beslutninger"></a>

**B1 — Dispatch on role, not on scope.** The roles in a scope are split by
`jit_mechanism` and sent to their respective composite. Fields are explicitly
projected into each module interface instead of being passed through as-is, so
that a field that does not belong cannot be smuggled through.

**B2 — Nullable defaults in the root.** The activation fields are `null` in the
variable type and receive their defaults in `main.tf`. Necessary so that
`entra_role` can reject them. The cost is that a layer below with its own default
can override — that is the reason the `"permanent"` sentinel is a string and not
`null`.

**B3 — One approval_stage.** Verified in both provider schemas:
`approval_stage` has `max_items = 1`, `primary_approver` is a set with no
upper limit. `dual` therefore places both approvers in the same stage. True
two-stage approval belongs in the access package request.

**B4 — The approver group is created in the module root, not in composites.** One
scope can have roles across multiple mechanisms. If the group were in the
composite layer, a mixed scope would get two groups with the same `display_name`,
and `prevent_duplicate_names` would fail the apply.

**B5 — Service principal as group owner.** See above. Accepted because the
alternative is worse, not because it is ideal.

---

## Submodules

| Module | Providers | Responsibility |
| --- | --- | --- |
| `entra-groups` | `azuread` | Cloud-agnostic security groups. Shared by all three. |
| `azure-rbac-on-group` | `azurerm` | Azure RBAC + PIM for Azure Resources. Only Azure-specific leaf. |
| `pim-for-groups` | `azuread` + `time` | PIM for Groups policy and eligibility. |
| `azure-subscription-access` | `azuread` + `azurerm` | Composite M2. |
| `pim-group-access` | `azuread` + `time` | Composite M3. |
| `entra-role-access` | `azuread` + `time` | Composite M4. |

Provider isolation is verifiable:

```bash
cd modules/access-vending/modules/pim-group-access
terraform init -backend=false && terraform providers
# should show azuread + time, no azurerm
```
