# Forutsetninger — tilganger og lisenser

Hva identiteten som kjører Terraform må ha, før første `apply`. Manglende
permissions er den vanligste blokkeren, og feilene den gir er 403-er som ikke
alltid sier hva som mangler.

To scenarioer dekkes:

| Scenario | Identitet | Når |
|---|---|---|
| **Demo / POC** | egen brukerkonto via `az login` | nå, manuell kjøring |
| **Mål** | service principal | CI, automatisert kjøring |

Kravene er ikke de samme. En brukerkonto autoriseres av **directory-roller**, en
service principal av **application permissions** i Microsoft Graph.

---

## 1. Demo — kjøring fra egen brukerkonto

Dette er oppsettet for manuell demo. `azuread`- og `azurerm`-provideren
autentiserer via Azure CLI.

```bash
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
```

### Entra directory-roller brukeren trenger

| Rolle | Trengs for |
|---|---|
| **Groups Administrator** eller **User Administrator** | opprette og oppdatere `azuread_group` |
| **Privileged Role Administrator** | konfigurere PIM for Groups — policy og eligibility |
| **Identity Governance Administrator** | access packages og katalog (repo 2) |

Microsoft oppgir at det kreves minst User Administrator for å opprette gruppa,
og minst Privileged Role Administrator for å ta den under PIM-forvaltning
([Microsoft Learn](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-eligible)).

`Groups Administrator` er den minst privilegerte som holder for gruppedelen —
foretrekk den over `User Administrator` hvis du bare skal lage grupper.

### Azure RBAC brukeren trenger

Per subscription som skal få tilgangsgrupper:

| Rolle | Trengs for |
|---|---|
| **User Access Administrator** eller **Owner** | opprette rollebindinger, permanente og eligible |

`Contributor` er **ikke** nok. Den kan ikke tildele roller.

### Sjekk før du kjører

```bash
# Kva er eg logga inn som?
az ad signed-in-user show --query "{upn:userPrincipalName, id:id}" -o json

# Har eg rolletildelingsrettar på subscriptionen?
az role assignment list --assignee <din-object-id> \
  --scope /subscriptions/<sub-id> \
  --query "[].roleDefinitionName" -o tsv
```

---

## 2. Mål — service principal

For CI. Trenger **application permissions** i Microsoft Graph, grantet med admin
consent — delegated holder ikke, siden det ikke finnes en innlogget bruker.

| Graph-permission | Trengs for | Feiler med |
|---|---|---|
| `Group.ReadWrite.All` | opprette og oppdatere grupper | 403 på `azuread_group` |
| `RoleManagementPolicy.ReadWrite.AzureADGroup` | PIM-aktiveringspolicy | 403 på `azuread_group_role_management_policy` |
| `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup` | eligible gruppemedlemskap | 403 på eligibility schedule |
| `EntitlementManagement.ReadWrite.All` | access packages (repo 2) | 403 i repo 2 |

Kjør scriptet, eller sett dem manuelt i Entra-portalen:

```bash
./scripts/grant-graph-permissions.sh <app-id>
```

Pluss Azure RBAC som over: **User Access Administrator** eller **Owner** på hver
target-subscription.

### Én begrensning verdt å kjenne

Service principals kan ikke selv beskyttes med JIT. Microsoft oppgir at eligible
rolletildelinger ikke kan opprettes for applikasjoner, service principals eller
managed identities, fordi de ikke kan utføre aktiveringen
([Azure RBAC og PIM](https://learn.microsoft.com/en-us/azure/role-based-access-control/pim-integration)).

Terraform-identiteten er derfor en **stående høyprivilegert identitet**. Scope
den via management group heller enn per subscription, og behandle credentialene
som det den er.

---

## 3. Lisenser

| Lisens | Trengs for |
|---|---|
| **Entra ID P2** | PIM for Groups, PIM for Azure Resources, entitlement management |
| **Entra ID Governance** eller **Entra Suite** | tildele *eligible* gruppemedlemskap via access package |

Governance-kravet gjelder spesifikt kombinasjonen «eligible rolle *via* access
package», som er M3 i `MALARKITEKTUR.md`. Ren P2 dekker både entitlement
management og PIM for Groups isolert
([Microsoft Learn](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-eligible)).

**Status:** Governance-lisens bekreftet på plass.

---

## 4. Per spor i målarkitekturen

Hva som faktisk trengs varierer med hvilket spor du bygger.

### M2 — Azure, JIT på rollenivå

- Azure RBAC: `User Access Administrator` eller `Owner` på scopet
- Entra: ingenting utover gruppeopprettelse — **M2-gruppene PIM-forvaltes ikke**
- Ingen `RoleManagementPolicy.ReadWrite.AzureADGroup` nødvendig for dette sporet

### M3 — andre skyer, JIT på medlemskap

- Entra: `Privileged Role Administrator` eller tilsvarende Graph-permissions
- Gruppa **må** være PIM-forvaltet
- Governance-lisens for `EligibleMember` via access package
- SCIM-provisionering satt opp mot skyens enterprise application

---

## 5. Vanlige feil

| Symptom | Årsak |
|---|---|
| 403 ved første `apply` på gruppe | mangler `Group.ReadWrite.All` eller Groups Administrator |
| 403 på PIM-policy | mangler Privileged Role Administrator / `RoleManagementPolicy.ReadWrite.AzureADGroup` |
| `AuthorizationFailed` på rollebinding | har `Contributor`, trenger `User Access Administrator` |
| `RoleAssignmentRequestPolicyValidationFailed` | PIM-policy mangler på gruppa — se [provider-issue #1450](https://github.com/hashicorp/terraform-provider-azuread/issues/1450) |
| «not found» på nyopprettet gruppe | Graph-propagering. Kjør på nytt, eller øk `propagation_delay` |

---

*Kildeinnhold er omskrevet for å overholde lisensvilkår.*
