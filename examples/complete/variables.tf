variable "tenant_id" {
  description = "Entra tenant ID. Used only by the azuread provider."
  type        = string
}

variable "provider_subscription_id" {
  description = <<-EOT
    Subscription ID the azurerm provider authenticates against. Required even
    without azure_pim roles, because azurerm needs a configurable provider block.
  EOT
  type        = string
}

variable "access_scopes" {
  description = <<-EOT
    Access scopes and roles. The field reference is in
    modules/access-vending/README.md.

    The type is `any` here because the module owns the type definition and
    validations. An error in tfvars is therefore reported against
    module.access_vending — the error message is the same.
  EOT
  type        = any
  default     = {}
}

variable "cloud_prefix" {
  description = "Default prefix on group names when a scope does not set `cloud`."
  type        = string
  default     = "azure"
}

variable "group_description_template" {
  description = "Template for group description. null gives the mechanism's own default."
  type        = string
  default     = null
}

variable "set_systemeier_as_group_owner" {
  description = <<-EOT
    Whether system owners should be set as group owners. Default false.

    false does NOT mean "no owners" — Graph makes the identity running Terraform
    an owner, and it cannot be removed. See modules/access-vending/README.md.
  EOT
  type        = bool
  default     = false
}

variable "pim_group_propagation_delay" {
  description = "Wait time for Graph propagation before PIM resources are created."
  type        = string
  default     = "30s"
}
