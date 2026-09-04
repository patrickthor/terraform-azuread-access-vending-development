# ==============================================================================
# Outputs
#
# Most map outputs are keyed on composite key "{scope}--{role}", across all
# three JIT mechanisms. The contract with the access-package repo is group_names
# plus access_package_access_type.
#
# EXCEPTION: approver_group_* are keyed on SCOPE key, not composite key, because
# the approver group is shared by all roles under a scope.
# ==============================================================================

locals {
  # Flat lookup table of all roles, regardless of mechanism. Used by outputs
  # that do not need to go through the modules.
  all_roles = merge([
    for scope_key, scope in var.access_scopes : {
      for role_key, role in scope.roles : "${scope_key}--${role_key}" => role
    }
  ]...)

  # Group names are fetched from the modules, not recalculated here. The naming
  # formula should live in one place — duplicated in the root it could diverge
  # from what the groups actually get.
  group_names_by_key = merge(
    merge([
      for scope_key, mod in module.azure_pim_access : {
        for role_key, name in mod.group_names : "${scope_key}--${role_key}" => name
      }
    ]...),
    merge([
      for scope_key, mod in module.pim_group_access : {
        for role_key, name in mod.group_names : "${scope_key}--${role_key}" => name
      }
    ]...),
    merge([
      for scope_key, mod in module.entra_role_access : {
        for role_key, name in mod.group_names : "${scope_key}--${role_key}" => name
      }
    ]...),
  )
}

output "group_names" {
  description = <<-EOT
    Group names per composite key "{scope}--{role}". This is the contract with
    the access-package repo: the same string is used as display_name in
    data "azuread_group" there.
  EOT
  value       = local.group_names_by_key
}

output "group_object_ids" {
  description = "Entra object IDs per composite key."
  value = merge(
    merge([
      for scope_key, mod in module.azure_pim_access : {
        for role_key, id in mod.group_object_ids : "${scope_key}--${role_key}" => id
      }
    ]...),
    merge([
      for scope_key, mod in module.pim_group_access : {
        for role_key, id in mod.group_object_ids : "${scope_key}--${role_key}" => id
      }
    ]...),
    merge([
      for scope_key, mod in module.entra_role_access : {
        for role_key, id in mod.group_object_ids : "${scope_key}--${role_key}" => id
      }
    ]...),
  )
}

output "jit_mechanism" {
  description = <<-EOT
    Which mechanism manages each composite key:

      "azure_pim"       M2. JIT in the role, PIM for Azure Resources.
      "pim_for_groups"  M3. JIT in the membership, PIM for Groups.
      "entra_role"      M4. JIT in the role, PIM for Entra roles. Activation
                        rules are set outside Terraform.
  EOT
  value       = { for k, role in local.all_roles : k => role.jit_mechanism }
}

output "access_package_access_type" {
  description = <<-EOT
    access_type repo 2 should use on the resource role binding per composite key.

      "Member"          azure_pim. Membership is active; the user activates the
                        ROLE in PIM for Azure Resources. Applies to both
                        permanent and eligible role assignments.

      "EligibleMember"  pim_for_groups. The access package makes the user
                        eligible, and the user activates the MEMBERSHIP.

      "Member"          entra_role. Membership is active; it is the directory
                        ROLE that is optionally activated in PIM.
  EOT
  value = {
    for k, role in local.all_roles :
    k => role.jit_mechanism == "pim_for_groups" ? "EligibleMember" : "Member"
  }
}

output "access_model" {
  description = <<-EOT
    Access model per composite key:

      "permanent"        azure_pim with permanent_access = true. The role is
                         permanently assigned; the time limit comes from expiry
                         on the access package assignment in repo 2.
      "eligible"         azure_pim with permanent_access = false. The group is
                         eligible for the role, members activate it themselves.
      "eligible_member"  pim_for_groups. The group is PIM-managed; it is the
                         membership that is activated.
  EOT
  value = merge(
    merge([
      for scope_key, mod in module.azure_pim_access : {
        for role_key, model in mod.access_model : "${scope_key}--${role_key}" => model
      }
    ]...),
    merge([
      for scope_key, mod in module.pim_group_access : {
        for role_key, model in mod.access_model : "${scope_key}--${role_key}" => model
      }
    ]...),
    merge([
      for scope_key, mod in module.entra_role_access : {
        for role_key, model in mod.access_model : "${scope_key}--${role_key}" => model
      }
    ]...),
  )
}

output "permanent_roles" {
  description = <<-EOT
    Composite keys with permanent role assignment. Applies to azure_pim and
    entra_role with permanent_access = true. pim_for_groups cannot be permanent.
  EOT
  value = sort([
    for k, role in local.all_roles : k
    if contains(["azure_pim", "entra_role"], role.jit_mechanism) && role.permanent_access
  ])
}

output "jit_roles" {
  description = "Composite keys that require an activation, regardless of mechanism."
  value = sort([
    for k, role in local.all_roles : k
    if role.jit_mechanism == "pim_for_groups" || !role.permanent_access
  ])
}

output "activation_settings" {
  description = "Effective activation rules per composite key that has an activation, for verification against the test checklist."
  value = merge(
    merge([
      for scope_key, mod in module.azure_pim_access : {
        for role_key, s in mod.activation_settings : "${scope_key}--${role_key}" => s
      }
    ]...),
    merge([
      for scope_key, mod in module.pim_group_access : {
        for role_key, s in mod.activation_settings : "${scope_key}--${role_key}" => s
      }
    ]...),
  )
}

# ------------------------------------------------------------------------------
# Mechanism-specific outputs
#
# These are not merged, because they have different shapes and meanings.
# ------------------------------------------------------------------------------

output "azure_role_assignment_scopes" {
  description = "Azure RBAC scope per composite key. Only azure_pim roles."
  value = merge([
    for scope_key, mod in module.azure_pim_access : {
      for role_key, scope in mod.role_assignment_scopes : "${scope_key}--${role_key}" => scope
    }
  ]...)
}

output "azure_activation_policy_ids" {
  description = <<-EOT
    Activation policy ID per "{scope}|{role}", per scope key. The key is not the
    role key, because azurerm_role_management_policy is keyed on (scope, role) in
    Azure and not per group.
  EOT
  value       = { for scope_key, mod in module.azure_pim_access : scope_key => mod.activation_policy_ids }
}

output "pim_group_policy_ids" {
  description = "PIM for Groups policy ID per composite key. Only pim_for_groups roles."
  value = merge([
    for scope_key, mod in module.pim_group_access : {
      for role_key, id in mod.activation_policy_ids : "${scope_key}--${role_key}" => id
    }
  ]...)
}

output "target_cloud_bindings" {
  description = <<-EOT
    Work list for the cloud side, per composite key. Only pim_for_groups roles.

    Terraform does NOT connect these groups to anything in the target cloud. The
    group must be provisioned there with SCIM and bound to the role there. This
    is what that binding should be.
  EOT
  value = merge([
    for scope_key, mod in module.pim_group_access : {
      for role_key, b in mod.target_cloud_bindings : "${scope_key}--${role_key}" => b
    }
  ]...)
}

output "entra_role_template_ids" {
  description = <<-EOT
    Template ID per composite key. Only entra_role roles.

    This is the roleDefinitionId that Graph uses. The activated directoryRole has
    a different object_id — see entra_role_object_ids.
  EOT
  value = merge([
    for scope_key, mod in module.entra_role_access : {
      for role_key, id in mod.directory_role_template_ids : "${scope_key}--${role_key}" => id
    }
  ]...)
}

output "entra_role_object_ids" {
  description = <<-EOT
    Object ID for the activated directory role per composite key. Always
    different from the template ID. Included because the confusion is a classic
    source of 400 from Graph.
  EOT
  value = merge([
    for scope_key, mod in module.entra_role_access : {
      for role_key, id in mod.directory_role_object_ids : "${scope_key}--${role_key}" => id
    }
  ]...)
}

output "entra_activation_governance_gap" {
  description = <<-EOT
    What Terraform does NOT manage for entra_role roles, per composite key.

    The azuread provider has no policy resource for directory roles, so MFA,
    approval, max activation duration and justification requirement must be set
    in the PIM portal. The output exists so that the gap is visible in plan and
    output, not only in a README.

    If this is empty, the configuration has no entra_role roles.
  EOT
  value = merge([
    for scope_key, mod in module.entra_role_access : {
      for role_key, g in mod.activation_governance_gap : "${scope_key}--${role_key}" => g
    }
  ]...)
}

output "demo_eligibility_schedules" {
  description = <<-EOT
    Eligible assignments Terraform itself has created, per composite key.

    Normally empty. Values here mean that demo_eligible_user_principal_names is
    in use, i.e. standing eligibility outside the access package flow.
  EOT
  value = merge([
    for scope_key, mod in module.pim_group_access : {
      for role_key, s in mod.eligibility_schedule_ids : "${scope_key}--${role_key}" => s
      if length(s) > 0
    }
  ]...)
}

# ------------------------------------------------------------------------------
# Summary for demo
# ------------------------------------------------------------------------------

output "access_summary" {
  description = <<-EOT
    One line per composite key: group name, mechanism, access model and what the
    access provides. Meant for reading the plan quickly during demo.
  EOT
  value = sort([
    for k, role in local.all_roles :
    format(
      "%-40s  %-14s  %-15s  %s",
      lookup(local.group_names_by_key, k, "(unknown)"),
      role.jit_mechanism,
      role.jit_mechanism == "pim_for_groups" ? "eligible_member" : (role.permanent_access ? "permanent" : "eligible"),
      coalesce(role.azure_role, role.target_role, role.entra_role, "")
    )
  ])
}

# ==============================================================================
# Approver groups
#
# Keyed on SCOPE key, not composite key: one group approves all roles under the
# scope.
#
# This is the second half of the contract with repo 2. Repo 2 should create an
# access package that grants membership in these groups, so that the approval
# right is vended like all other access instead of being a hand-picked list.
# ==============================================================================

output "approver_group_names" {
  description = <<-EOT
    Group names per scope key for the approver group.

    Scopes without any role with approval_type "dual" are not listed
    here — they have no group approval, and therefore no group.

    Repo 2 looks up this name with data "azuread_group", the same way as for the
    role groups.
  EOT
  value       = local.approver_group_names
}

output "approver_group_object_ids" {
  description = "Entra object ID per scope key for the approver group."
  value       = local.approver_group_object_ids
}

output "approver_group_is_managed_here" {
  description = <<-EOT
    Whether the approver group for the scope is CREATED by this repo (true) or
    looked up as an existing group (false).

    If false, someone has set approver_group_name on the scope, and the group
    lives outside the vending. Then the membership — i.e. the approval right —
    is not necessarily vended through an access package either.
  EOT
  value = {
    for scope_key, scope in local.scopes_with_group_approval :
    scope_key => scope.approver_group_name == null
  }
}

output "approvers_by_role" {
  description = <<-EOT
    Who approves activation per composite key. Derived from approval_type:

      "self"   no approver
      "owner"  the systemeier list
      "dual"   the systemeier list AND the approver group

    NOTE: all approvers are in the SAME approval_stage — the provider schema only
    allows one. That is why it is enough that ONE of them signs, even with
    "dual". More approvers give broader coverage, not stricter control.

    Permanent roles are not listed here: they are never activated, so they are
    never approved.
  EOT
  value = {
    for k, role in local.all_roles : k => {
      approval_type = role.jit_mechanism == "entra_role" ? "not managed by Terraform" : coalesce(role.approval_type, "owner")

      systemeier_approves = role.jit_mechanism != "entra_role" && contains(
        ["owner", "dual"], coalesce(role.approval_type, "owner")
      )

      approver_group = (
        role.jit_mechanism != "entra_role" && coalesce(role.approval_type, "owner") == "dual"
        ? lookup(local.approver_group_names, split("--", k)[0], null)
        : null
      )
    }
    if !(role.jit_mechanism == "azure_pim" && role.permanent_access)
  }
}

output "systemeier_by_scope" {
  description = <<-EOT
    The systemeier UPN list per scope key.

    Exposed so the access-package repo (repo 2) can resolve the same system
    owners as named approvers on the access package REQUEST gate, without
    re-declaring them in its own tfvars. Repo 2 looks each UPN up with
    data "azuread_user".

    Note this is the REQUEST-side approver source. It is the same list repo 1
    uses for PIM ACTIVATION approval (see approvers_by_role), but the two gates
    are distinct points in the flow — repo 2 may choose to route them
    differently.
  EOT
  value       = { for scope_key, scope in var.access_scopes : scope_key => scope.systemeier }
}

# ==============================================================================
# THE MACHINE CONTRACT
#
# Everything above is for humans reading a plan. This is the single
# machine-readable output, and repo 2 accepts exactly this object as its only
# machine-readable input. Shape is defined in
# .kiro/steering/identity-governance-contract.md, which must stay byte-identical
# in both repos.
#
# Assembly lives in locals (contract_roles / contract_scopes / contract_catalogs)
# so the plan-time key guarantee is reviewable in one place. See the long comment
# on THE MACHINE CONTRACT in main.tf.
# ==============================================================================

output "contract" {
  description = <<-EOT
    The machine-readable contract consumed by the access-packages repo (repo 2)
    as `module.access_packages.vending`.

    Repo 2 uses `roles`, `scopes`, `catalogs`, `role_keys` and `scope_keys` as
    for_each sources, so every KEY here is derived from var.access_scopes alone
    and is known at plan time. Values may be unknown until apply —
    group_object_id always is — which is fine, because unknown values only break
    for_each and count.

    Wire it up in the customer root as:

      module "access_packages" {
        source  = "github.com/patrickthor/terraform-azuread-access-packages-development//modules/access-packages?ref=v1.0.0"
        vending = module.access_vending.contract
      }

    Do NOT wrap contract fields in try() on the consuming side. A missing
    access_type must fail loudly: papering over it is how just-in-time
    eligibility silently becomes standing membership.
  EOT

  value = {
    # A LITERAL, never derived — it has to be greppable across both repos.
    # Additive fields do not bump it. Removing, renaming, or changing the meaning
    # of a field does.
    contract_version = 1

    roles    = local.contract_roles
    scopes   = local.contract_scopes
    catalogs = local.contract_catalogs
  }
}

output "catalog_privilege_notes" {
  description = <<-EOT
    Warning-level note, NOT a validation failure.

    Lists scopes whose roles are all `entra_role` and which share a catalog with
    other scopes. Directory-role access is the highest-privilege thing this
    system vends, so it is worth being easy to spot in a catalog listing.

    Empty list means nothing to look at. A non-empty list is not an error: one
    identity team owning everything means one catalog is the correct design. Give
    such a scope its own `catalog` label only if a different team should own the
    packages built on it.
  EOT
  value       = local.entra_only_scopes_sharing_catalog
}
