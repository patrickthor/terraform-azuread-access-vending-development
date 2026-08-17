variable "identity_name" {
  description = "Name of the managed identity, e.g. id-access-vending-poc-bvt."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the managed identity."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "norwayeast"
}

variable "create_resource_group" {
  description = "Whether the resource group should be created. false expects it to exist."
  type        = bool
  default     = false
}

variable "github_org" {
  description = "GitHub organization."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo, just the repo name — not org/repo."
  type        = string
}

variable "github_branch" {
  description = <<-EOT
    Branch that is trusted by the OIDC federation.

    Federated credentials are bound to a specific branch. If it points to a
    branch where anyone can push, anyone with push access can manage access in
    the tenant. Use a protected branch.
  EOT
  type        = string
  default     = "main"
}

variable "state_storage_account_id" {
  description = <<-EOT
    Resource ID of the storage account holding tfstate, so the identity gets
    "Storage Blob Data Contributor" on it.

    null skips the role binding — use this if the account is in a different
    subscription or managed elsewhere.
  EOT
  type        = string
  default     = null
}
