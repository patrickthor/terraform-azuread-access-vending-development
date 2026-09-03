# Harness

`variables.tf` is a **symlink** to `modules/access-vending/variables.tf`.

The point of this fixture is to exercise the module's real variable validations.
A copy would drift from the thing under test and quietly stop testing it, so the
real file is referenced directly.

A directory containing only variable declarations is a valid Terraform module and
needs no providers — which is what lets `terraform plan` reach variable
validation without Azure credentials.
