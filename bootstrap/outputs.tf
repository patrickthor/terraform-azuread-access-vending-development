output "identity_client_id" {
  description = "Client ID. Store as GitHub secret AZURE_CLIENT_ID."
  value       = module.bootstrap.identity_client_id
}

output "identity_principal_id" {
  description = "Principal ID. Used by ./grant-graph-permissions.sh and for RBAC assignments."
  value       = module.bootstrap.identity_principal_id
}

output "identity_tenant_id" {
  description = "Tenant ID. Store as GitHub secret AZURE_TENANT_ID."
  value       = module.bootstrap.identity_tenant_id
}

output "next_steps" {
  description = "What must be done manually after this apply."
  value       = <<-EOT

    1. Grant Graph permissions (requires Privileged Role Administrator):

         ./grant-graph-permissions.sh

    2. Grant the identity permissions on each subscription to be vended.
       The azure_pim track writes role bindings AND PIM policies, and both
       require one of these:

         az role assignment create \
           --assignee-object-id ${module.bootstrap.identity_principal_id} \
           --assignee-principal-type ServicePrincipal \
           --role "User Access Administrator" \
           --scope /subscriptions/<subscription-id>

       "Role Based Access Control Administrator" is tighter and is enough for
       role bindings, but NOT for PIM policies — those require Owner or
       User Access Administrator.

    3. Add GitHub secrets and variables. See
       examples/github-consumption/README.md.

  EOT
}
