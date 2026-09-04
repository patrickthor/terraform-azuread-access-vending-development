# ==============================================================================
# Root variables
#
# Two groups:
#
#   1. tenant_id and provider_subscription_id — exist ONLY to configure the
#      providers in providers.tf. They are not passed to the module, and they
#      disappear when you call the module directly from your own repo.
#
#   2. The rest is passthrough to modules/access-vending.
# ==============================================================================

# ------------------------------------------------------------------------------
# Provider configuration — not part of the module's interface
# ------------------------------------------------------------------------------

variable "tenant_id" {
  description = <<-EOT
    Entra tenant ID. Used only by the azuread provider in providers.tf.

    Can alternatively be set with ARM_TENANT_ID in the environment, but is
    required here because a tenant ID that is not explicit is a common cause of
    vending access in the wrong tenant.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "provider_subscription_id" {
  description = <<-EOT
    Subscription ID that the azurerm provider authenticates against.

    Role assignments use explicit scope per subscription, so this only needs to
    point to one subscription the identity has access to.

    Required even in a configuration without azure_pim roles. The reason is that
    azurerm requires a provider block because of features {}, and the block must
    be configurable even if no azurerm resources are created. This is a provider
    limitation, not a design choice — and it will not go away until
    azure-rbac-on-group potentially switches to azapi.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.provider_subscription_id))
    error_message = "provider_subscription_id must be a GUID."
  }
}

# ------------------------------------------------------------------------------
# Passthrough to the module
# ------------------------------------------------------------------------------

variable "access_scopes" {
  description = <<-EOT
    Access scopes and their roles. See modules/access-vending/README.md for the
    field reference, and examples/complete/terraform.tfvars.example for a working
    setup with all three JIT mechanisms.

    THE TYPE IS `any` ON PURPOSE. The module owns the type definition and the 33
    validations. If the type were repeated here, it would be ~180 lines of
    duplicated schema that is guaranteed to diverge from the module's over time —
    and the module is the one that actually enforces it.

    Practical consequence: an error in terraform.tfvars is reported against
    module.access_vending, not against the root. The error message is the same,
    and it is good — the validations in the module explain why a field is
    rejected, not just that it is.
  EOT
  type        = any
  default     = {}
}

variable "cloud_prefix" {
  description = "Default prefix on group names when a scope does not set `cloud` itself."
  type        = string
  default     = "azure"
}

variable "default_catalog" {
  description = <<-EOT
    Catalog label applied to scopes that do not set `catalog` themselves.

    This repo creates no catalogs. The label is forwarded in the `contract`
    output, and the access-packages repo (repo 2) creates or adopts one catalog
    per distinct label. The label is a delegation boundary, so it should track
    ownership rather than environment.
  EOT
  type        = string
  default     = "cloud-access"
}

variable "group_description_template" {
  description = <<-EOT
    Template for group description. Placeholders: {cloud}, {sub}, {role},
    {target_role}, {scope_id}. null gives each mechanism its own default.
  EOT
  type        = string
  default     = null
}

variable "set_systemeier_as_group_owner" {
  description = <<-EOT
    Whether the system owners should be set as owners on the groups. Default
    false, on purpose — see the module's variable for the full rationale.

    NOTE: false does not mean "no owners". Graph assigns ownership to the
    identity running Terraform, and it cannot be removed. See
    modules/access-vending/README.md.
  EOT
  type        = bool
  default     = false
}

variable "pim_group_propagation_delay" {
  description = <<-EOT
    Wait time before PIM resources are created on newly created groups, so they
    can propagate in Graph. Applies to the pim_for_groups AND entra_role track.
  EOT
  type        = string
  default     = "30s"
}
