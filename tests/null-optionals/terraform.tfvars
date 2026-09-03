# ==============================================================================
# The reproduction case: every optional field omitted.
#
# This is legitimate, documented configuration. Before the v0.1.1 fix it broke
# `terraform plan` with "argument must not be null" from the approval_type and
# max_activation_hours validations.
#
# Committed on purpose — it is test input, not a secret. The GUIDs are all-zero
# placeholders and no provider ever authenticates with them.
# ==============================================================================

access_scopes = {

  # --------------------------------------------------------------------------
  # azure_pim with the activation fields omitted entirely.
  #
  # Legitimate for permanent_access = true, where activation settings have no
  # meaning at all — and legitimate for eligible roles too, since the module
  # documents that null yields the defaults (owner, 8h).
  # --------------------------------------------------------------------------
  "azure-minimal" = {
    cloud      = "azure"
    scope_id   = "00000000-0000-0000-0000-000000000000"
    systemeier = ["a@example.com", "b@example.com"]

    roles = {
      # Omits approval_type, max_activation_hours, require_mfa,
      # require_justification, require_ticket_info, eligible_duration_days.
      "reader" = {
        azure_role       = "Reader"
        permanent_access = true
      }

      # Eligible, and still omits every activation field. Exercises the defaults
      # path (approval_type -> owner, max_activation_hours -> 8).
      "contributor" = {
        azure_role = "Contributor"
      }

      # approval_type set, max_activation_hours omitted — the mixed case.
      "operator" = {
        azure_role    = "Storage Blob Data Reader"
        approval_type = "self"
      }

      # dual, so the scope gets an approver group; other fields omitted.
      "owner" = {
        azure_role    = "Owner"
        approval_type = "dual"
      }
    }
  }

  # --------------------------------------------------------------------------
  # pim_for_groups with active_assignment_expire_after and
  # eligible_assignment_expiration_required omitted.
  # --------------------------------------------------------------------------
  "aws-minimal" = {
    cloud      = "aws"
    scope_id   = "000000000000"
    systemeier = ["c@example.com"]

    roles = {
      # Omits everything optional.
      "readonly" = {
        jit_mechanism = "pim_for_groups"
        target_role   = "ReadOnlyAccess"
      }

      # The "permanent" sentinel must still be accepted as a string.
      "billing" = {
        jit_mechanism                  = "pim_for_groups"
        target_role                    = "Billing"
        approval_type                  = "dual"
        active_assignment_expire_after = "permanent"
      }

      # A real duration, to prove the non-null path still validates.
      "admin" = {
        jit_mechanism                  = "pim_for_groups"
        target_role                    = "AdministratorAccess"
        max_activation_hours           = 4
        require_mfa                    = true
        active_assignment_expire_after = "P15D"
      }
    }
  }

  # --------------------------------------------------------------------------
  # entra_role — activation fields MUST stay null here, since the module rejects
  # them outright. This is the case where null-vs-set has to remain
  # distinguishable, so it must never be "fixed" with coalesce().
  # --------------------------------------------------------------------------
  "entra-minimal" = {
    cloud      = "entra"
    scope_id   = "/"
    systemeier = ["d@example.com"]

    roles = {
      "groupsadmin" = {
        jit_mechanism = "entra_role"
        entra_role    = "Groups Administrator"
      }

      "directoryreader" = {
        jit_mechanism    = "entra_role"
        entra_role       = "Directory Readers"
        permanent_access = true
      }
    }
  }
}
