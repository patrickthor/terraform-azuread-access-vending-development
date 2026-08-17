#!/usr/bin/env bash
#
# Grants Microsoft Graph application permissions to the deploy identity.
#
# Run after `terraform apply` in this directory. The script reads the principal ID
# from Terraform output if you do not provide an app ID yourself.
#
#   ./grant-graph-permissions.sh                    # reads from terraform output
#   ./grant-graph-permissions.sh <client-id>        # explicit
#
# Requires that YOU are logged in as Privileged Role Administrator or Global
# Administrator: az login
#
# ------------------------------------------------------------------------------
# WHY THIS IS NOT TERRAFORM
#
# Graph application permissions require admin consent, and the consent flow is
# unreliable in Terraform. More importantly: this is the most privileged
# operation in the entire setup, and an admin should read the list before running
# it. It is a deliberate security choice that the step is manual and visible.
# ------------------------------------------------------------------------------

set -euo pipefail

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# ------------------------------------------------------------------------------
# Permissions
#
# Divided by which track needs them, so you can cut what you do not use. The
# script grants all — comment out what you do not need.
# ------------------------------------------------------------------------------
PERMISSIONS=(
  # --- All tracks -------------------------------------------------------------
  # Creates and updates the groups.
  #
  # NOTE: Group.Create is tighter and is enough for creation, but the module
  # also updates description and ownership on existing groups, so ReadWrite is
  # needed. The consequence is write access on ALL groups in the tenant. A
  # tighter alternative is the Entra role "Groups Administrator", optionally
  # scoped to an administrative unit, instead of tenant-wide app permission.
  "Group.ReadWrite.All"

  # Looks up system owners and any fixed members by UPN.
  #
  # Group.ReadWrite.All does NOT grant read access to users. Without this,
  # `data "azuread_user"` fails with 403 for every configuration that has
  # approval_type "owner" or "dual" — in practice all of them. The error message
  # points to the user lookup, not the group, so it is easy to misinterpret.
  "User.Read.All"

  # --- M3: pim_for_groups ----------------------------------------------------
  # The activation policy on the group. Writing the policy is also what onboards
  # the group to PIM for Groups — there is no explicit onboarding.
  "RoleManagementPolicy.ReadWrite.AzureADGroup"

  # Eligible membership in the group. Only used by
  # demo_eligible_user_principal_names; in normal operation eligibility comes
  # from the access package in repo 2.
  "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup"

  # --- M4: entra_role --------------------------------------------------------
  # Activates directory roles and creates role-assignable groups.
  #
  # WARNING: this is the most powerful permission in the list. It lets the
  # identity assign directory roles across the entire tenant, including to
  # itself. Only include it if you actually use jit_mechanism = "entra_role".
  #
  # Group.ReadWrite.All is not enough for membership in role-assignable groups —
  # that requires precisely this permission.
  "RoleManagement.ReadWrite.Directory"

  # Eligible directory role bindings.
  "RoleEligibilitySchedule.ReadWrite.Directory"
)

# ------------------------------------------------------------------------------

if [[ $# -ge 1 ]]; then
  APP_ID="$1"
else
  echo "No app ID provided — reading from terraform output..."
  if ! APP_ID="$(terraform output -raw identity_client_id 2>/dev/null)"; then
    echo "ERROR: no terraform output found. Run 'terraform apply' first," >&2
    echo "       or provide the client ID as an argument." >&2
    exit 1
  fi
fi

echo "Looking up service principal for app ${APP_ID}..."
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id --output tsv)"
GRAPH_SP_OBJECT_ID="$(az ad sp show --id "${GRAPH_APP_ID}" --query id --output tsv)"

echo "Service principal object ID: ${SP_OBJECT_ID}"
echo

for PERMISSION in "${PERMISSIONS[@]}"; do
  echo "Processing ${PERMISSION}..."

  ROLE_ID="$(az ad sp show --id "${GRAPH_APP_ID}" \
    --query "appRoles[?value=='${PERMISSION}'].id | [0]" \
    --output tsv)"

  if [[ -z "${ROLE_ID}" || "${ROLE_ID}" == "None" ]]; then
    echo "  ERROR: could not find app role for ${PERMISSION}" >&2
    exit 1
  fi

  # Idempotent: skip if the assignment already exists.
  EXISTING="$(az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --query "value[?appRoleId=='${ROLE_ID}'] | [0].id" \
    --output tsv 2>/dev/null || true)"

  if [[ -n "${EXISTING}" && "${EXISTING}" != "None" ]]; then
    echo "  Already granted, skipping."
    continue
  fi

  az rest \
    --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${SP_OBJECT_ID}\",
      \"resourceId\": \"${GRAPH_SP_OBJECT_ID}\",
      \"appRoleId\": \"${ROLE_ID}\"
    }" \
    --output none

  echo "  Granted."
done

cat <<EOF

Done. Verify in the Entra portal under App registrations >
${APP_ID} > API permissions that all are listed as "Granted".

Or read it from the token — for an app-only token permissions are in the
roles claim, not in scp:

  az account get-access-token --resource-type ms-graph --query accessToken -o tsv \\
    | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.roles[]' | sort

REMAINING: Graph permissions cover the Entra side. The azure_pim track also
writes Azure RBAC and PIM policies, and that requires "User Access Administrator"
or "Owner" on each subscription. See the output "next_steps" from terraform apply.
EOF
