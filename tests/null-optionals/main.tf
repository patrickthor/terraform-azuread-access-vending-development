# ==============================================================================
# Regression fixture — every optional field omitted
#
# Guards against the null-guard bug fixed in v0.1.1: validations written as
#
#     x == null || contains(list, x)
#
# are NOT null-safe. Terraform's `||` does not reliably short-circuit, so the
# null reaches contains() (or `>=`) and plan fails with
#
#     Invalid value for "value" parameter: argument must not be null.
#     Error during operation: argument must not be null.
#
# The bug only surfaced when the module was consumed from a git source, and only
# during `plan` — `terraform validate` does not load tfvars, and module variable
# validation runs during the graph walk. So neither `validate` nor a local-path
# module call caught it.
#
# ------------------------------------------------------------------------------
# WHY THIS FIXTURE HAS NO PROVIDERS
#
# Variable validation runs during the graph walk, after provider configuration.
# With real providers declared, plan dies on Azure authentication long before it
# reaches the validations — which is exactly why the bug was missed.
#
# This fixture therefore declares NO providers and instantiates NO resources: it
# only passes access_scopes into the real module's typed variable, through an
# any-typed root variable, mirroring how a consumer repo does it. That is enough
# to force every validation to evaluate, with no credentials required.
#
#   cd tests/null-optionals
#   terraform init -backend=false
#   terraform plan            # must succeed
#
# It is wired into .github/workflows/validate.yml so it runs on every push.
#
# ------------------------------------------------------------------------------
# KNOWN LIMITATION — READ BEFORE TRUSTING THIS TEST
#
# This fixture did NOT reproduce the original bug. With the old broken guard
# restored, it plans cleanly on both Terraform 1.14.5 and 1.16.1 locally, using
# both a synthetic null-heavy config and the real POC terraform.tfvars. The
# failure was only ever observed in CI, against a git-sourced module with
# existing remote state.
#
# The most likely explanation: Terraform's `||` can short-circuit when both
# operands are known, but a plan that refreshes existing state has *unknown*
# values in its graph, and an unknown operand forces both sides to be evaluated
# — at which point the null reaches contains() and fails. This fixture creates
# no resources, so nothing in its graph is ever unknown, and the short-circuit
# path is always taken.
#
# So: this guards the simple case and documents the contract, but it is NOT
# proof that the null-guard bug cannot return. Only a real plan against real
# state is. Treat a green run here as necessary, not sufficient.
# ==============================================================================

terraform {
  required_version = ">= 1.9"
}

# any-typed, exactly like the real root and the consumption example, so nothing
# is coerced or defaulted before the module's own type constraint sees it.
variable "access_scopes" {
  type    = any
  default = {}
}

# ------------------------------------------------------------------------------
# The module's variable declarations are what we are testing, so reference the
# real file rather than a copy that could drift.
#
# This does NOT create resources: validation of an input variable is evaluated
# whether or not anything downstream consumes it.
# ------------------------------------------------------------------------------
module "validations" {
  source        = "./harness"
  access_scopes = var.access_scopes
}

output "scopes_accepted" {
  description = "Non-empty means every validation accepted the null-heavy input."
  value       = keys(var.access_scopes)
}
