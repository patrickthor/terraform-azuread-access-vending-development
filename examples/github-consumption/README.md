# Consuming access-vending from your own repo

The minimum setup to run access vending in your own project, with GitHub Actions
and OIDC. No credentials are stored in GitHub.

## Files

```
main.tf                        Module call (pinned ref) + forwarded outputs
variables.tf                   Declarations
versions.tf                    Provider blocks + backend
terraform.tfvars               YOUR access configuration — COMMIT THIS
.github/workflows/deploy.yml   Workflow — copy to your repo's .github/workflows/
```

Four files plus the workflow. Copy this directory into your project, then:

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars, then commit it
```

The field reference for `access_scopes` lives in the module:
[`modules/access-vending/README.md`](../../modules/access-vending/README.md).

## terraform.tfvars is committed — deliberately

Most Terraform templates gitignore `terraform.tfvars` and generate it in CI from
flat repository variables. That does not work here, and would not be desirable if
it did.

`access_scopes` is a deeply nested map describing arbitrary scopes and roles.
Serialising it from flat GitHub variables would be more fragile than the problem
it solves. More importantly, for an access-vending system **the configuration is
the governance record** — "who is systemeier for prod", "which roles require dual
approval" — and those are exactly the changes that should arrive as a reviewed
pull request with history. Holding them in a secret would remove that review.

If your `.gitignore` excludes `*.tfvars`, add an exception:

```gitignore
!terraform.tfvars
```

Real credentials stay out: `tenant_id` and `provider_subscription_id` reach
Terraform through `TF_VAR_` from GitHub secrets.

## Setup, in order

### 1. Create the CI identity

You need a service principal with an OIDC federated credential trusting **your**
repo and branch. The module repo's `bootstrap/` provisions a user-assigned managed
identity for this, but note that a managed identity has no client secret and can
only be used from CI — not from your laptop. For local work, create an app
registration instead.

Set the federated credential subject to your own repository:

```
repo:YOUR-ORG/YOUR-REPO:ref:refs/heads/main
```

Not the module source repo. A mismatch produces `AADSTS700024` at runtime.

### 2. Grant Graph permissions

Requires Privileged Role Administrator or Global Administrator. The module repo
ships an idempotent script:

```bash
./bootstrap/grant-graph-permissions.sh <your-client-id>
```

| Permission | Needed for |
| --- | --- |
| `Group.ReadWrite.All` | Create and update the groups |
| `User.Read.All` | Look up systemeier by UPN |
| `RoleManagementPolicy.ReadWrite.AzureADGroup` | PIM for Groups policy (`pim_for_groups`) |
| `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup` | Eligible group membership |
| `RoleManagement.ReadWrite.Directory` | **Only if you use `entra_role`** |
| `RoleEligibilitySchedule.ReadWrite.Directory` | **Only if you use `entra_role`** |

`RoleManagement.ReadWrite.Directory` lets the identity assign directory roles
anywhere in the tenant, including to itself. Omit it unless you use `entra_role`,
and use a dedicated service principal for this repo rather than a shared one.

### 3. Grant subscription RBAC — only for `azure_pim`

The `azure_pim` mechanism writes both role bindings and PIM policies. The policies
need `Owner` or `User Access Administrator`; the tighter
`Role Based Access Control Administrator` covers the bindings but **not** the
policies.

```bash
az role assignment create \
  --assignee-object-id <sp-object-id> \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope /subscriptions/<subscription-id>
```

Skip this entirely if you only use `pim_for_groups` or `entra_role`.

### 4. GitHub configuration

**Settings → Secrets and variables → Actions**

Secrets:

| Secret | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Client ID of the CI service principal |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription the azurerm provider authenticates to |

Variables:

| Variable | Example | Notes |
| --- | --- | --- |
| `AZURE_LOCATION` | `norwayeast` | Used when creating state storage |
| `STATE_RESOURCE_GROUP` | `rg-tfstate` | **Created automatically if missing** |
| `STATE_STORAGE_ACCOUNT` | `sttfstate1a2b` | **Created automatically if missing** |
| `STATE_CONTAINER` | `tfstate` | Optional, defaults to `tfstate` |
| `VENDING_STATE_KEY` | `access-vending.tfstate` | Optional |

### 5. Run it

Actions → **Deploy access vending** → Run workflow, and choose `plan`, `apply` or
`destroy`.

Dispatch-only is intentional: this repo decides who can become Groups
Administrator in your tenant, so an accidental push to `main` should not change
that. Choosing `apply` is the deliberate act.

On the first run the workflow also creates the state resource group, storage
account and container, and grants itself `Storage Blob Data Contributor`. Later
runs skip that and connect to the existing state.

## Bumping the module version

Edit the `?ref=` in `main.tf`:

```hcl
source = "github.com/patrickthor/terraform-azuread-access-vending-development//modules/access-vending?ref=v0.2.0"
```

Terraform requires `source` to be a literal string, so this cannot be a variable
— which is a feature here. The module creates groups that the access-package repo
looks up **by name**, so an upgrade that changes the naming convention breaks that
link, and the failure appears in the *other* repo as "group does not exist". A
version bump should be a reviewable diff.

Always run `plan` after bumping, before `apply`.

## Order of operations with the access-package repo

Vending must apply **first**. That is stricter than "the groups must exist": for
`pim_for_groups` the PIM policy must be written, or the access package
resource-role picker offers only `Member` and not `Eligible Member` — giving active
membership instead of JIT, with nothing failing.

If both repos run in one pipeline, use `needs:` between the jobs. Terraform does
not enforce the order.

## Before testing activation

The approver groups are **seeded with the systemeier**, so a `dual` role is
activatable from the first apply. But one member is not enough: an approver cannot
approve their own request, so a lone systemeier cannot activate their own `dual`
role — the request sits until it times out after 24 hours.

Give each scope at least two systemeier, or add further approvers through an access
package.

```bash
terraform output approver_group_names
terraform output approvers_by_role
terraform output access_summary
```

## Known gaps to be aware of

**`entra_role` activation rules are outside Terraform.** No policy resource exists
in the `azuread` provider for directory roles, so MFA, approval and maximum
duration must be set in the PIM portal. The access package request approval is the
only gate Terraform enforces on that path. See `entra_activation_governance_gap`
in the outputs, and R6 in the module README.

**`EligibleMember` cannot be set from Terraform.** The access-package repo will hit
this: `azuread_access_package_resource_package_association` accepts only `Member`
or `Owner`, so `pim_for_groups` groups cannot be attached as eligible resource
roles in code. Attaching them as `Member` grants active membership immediately,
defeating the JIT model without any error. Verify the behaviour in your first
end-to-end test.
