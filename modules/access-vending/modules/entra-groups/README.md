# Module: `entra-groups`

Creates cloud-only Entra security groups. **Cloud-agnostic** — uses only the
`azuread` provider and can be used without `azurerm` installed.

The group is the common primitive across clouds. This module knows nothing about
Azure RBAC, AWS permission sets, or GCP IAM.

## Naming

The module does **not** add a cloud prefix. The caller passes in the final name:

- Azure: `azure-{sub}-{role}`
- AWS: `aws-{account}-{role}`
- GCP: `gcp-{project}-{role}`

`display_name` and `mail_nickname` are set to the same string. `display_name` is
the lookup key against the access package repo; `mail_nickname` is unique in the
tenant and provides collision protection without changing the naming contract.

## Input

| Name | Type | Default | Description |
|---|---|---|---|
| `groups` | `map(object)` | `{}` | Groups keyed on a stable identifier. See below. |
| `prevent_duplicate_names` | `bool` | `true` | Error on apply if display_name already exists. |

`groups` object:

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | Fully prefixed group name. Only `[a-zA-Z0-9-]`, max 64 characters. |
| `description` | `string` | `""` | Description. |
| `owner_user_principal_names` | `list(string)` | `[]` | Owners, as UPN. |
| `member_user_principal_names` | `list(string)` | `[]` | Permanent members, as UPN. Normally empty. |
| `assignable_to_role` | `bool` | `false` | Force-replace in Entra. See warning below. |

## Output

| Name | Description |
|---|---|
| `group_object_ids` | Object ID per group key. |
| `group_names` | `display_name` per group key. |
| `groups` | Combined object with `object_id`, `display_name`, `mail_nickname`. |

## Call example

```hcl
module "groups" {
  source = "./modules/entra-groups"

  groups = {
    reader = {
      name        = "azure-sub-alpha-reader"
      description = "Read access on sub-alpha"
    }
    contributor = {
      name        = "azure-sub-alpha-contributor"
      description = "Contributor on sub-alpha, activated via PIM"
    }
  }
}
```

## Design choices worth knowing

**Membership is managed outside `azuread_group`.** The module does not set
`members`/`owners` on the group resource, but uses separate
`azuread_group_member` and `azuread_group_owner` resources, and has
`ignore_changes` on both attributes. The reason: access packages and
PIM activation add and remove members outside Terraform. If the member list were
part of the group resource, every `plan` would show drift and attempt to remove
them.

**`assignable_to_role` is force-replace.** Changing from `false` to `true` deletes
and recreates the group, which tears down all RBAC bindings and PIM policies
attached to it. Set it correctly from the start. `false` is sufficient for pure
Azure RBAC use.

**PIM management may require the group to be onboarded.** Groups with
`assignable_to_role = true` are automatically PIM-managed. Regular security
groups must normally be "discovered" by PIM first. See the `pim-for-groups` README
and [R1](../../README.md#risikoer) in the module README.
