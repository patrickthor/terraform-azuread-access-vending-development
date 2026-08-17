# Prosjektsammendrag — terraform-azuread-access-vending

**Start her** hvis du tar opp arbeidet etter en pause, eller åpner en ny
chat-sesjon på dette repoet. Fila er skrevet for å gi full kontekst uten at du
må lese koden først.

Sist oppdatert: 17. august 2026
Status: **førsteutkast, ikke kjørt mot Azure ennå**

> **Les `MALARKITEKTUR.md` før du endrer noe.** Det er besluttet en målarkitektur
> som overstyrer flere av beslutningene under — særlig B2 (lisens er nå på plass),
> og PIM-modellen for Azure. Beslutningene i dette dokumentet beskriver koden som
> den står i dag, ikke der den skal.

---

## 1. Hva dette repoet er

Oppgave 1 av 2 i POC-en for access packages på Azure (full oppgavetekst i
`OPPGAVE.md`). Repoet inneholder gjenbrukbare Terraform-moduler som per
subscription oppretter:

- Entra-sikkerhetsgrupper etter navnekonvensjonen `azure-{sub}-{rolle}`
- Permanent Azure RBAC-binding på gruppen
- PIM for Groups-policy og eligible-tildelinger for roller som krever det

Modulene skal kunne løftes rett inn i LZ-repoet uten omskriving.

Det andre repoet er **`terraform-azuread-access-packages`**, som slår opp
gruppene herfra på navn og lager access packages rundt dem.

### Apply-rekkefølge

```
1. terraform-azuread-access-vending      ← dette repoet, må kjøres først
2. terraform-azuread-access-packages     ← slår opp gruppene fra 1
```

---

## 2. POC-rammen i korte trekk

- POC-tenant med **Entra ID P2**, ingen Governance-tillegg.
- Access reviews og lifecycle workflows er utenfor scope. Erstattes av kort
  expiry på access package-tildelingen (7-14 dager) + manuell re-request.
- Azure er native Entra. Ingen SCIM, ingen Logic App.
- Subscription-opprettelse er utenfor scope. POC-en bruker 1-2 eksisterende
  test-subscriptions.
- Designen skal kunne videreføres til AWS/GCP/GitHub. Entra-gruppe + PIM for
  Groups er felles mekanisme; det som varierer per sky er hvordan gruppen kobles
  til skyens autorisasjon.
- **Ingen hardkoding av rollenavn.** `reader`/`contributor`/`owner` er bare
  eksempler; rolle er en fri streng.

### PIM-modellen (viktigste konsept)

Vi bruker **PIM for Groups**, ikke PIM for Azure Resources:

1. Gruppen har en **permanent** rolletildeling (Azure RBAC her).
2. Brukeren er **eligible member** av gruppen, ikke aktivt medlem.
3. Ved aktivering blir brukeren aktivt medlem i et tidsbegrenset vindu, med
   MFA/godkjenning/begrunnelse etter policy.
4. Når vinduet utløper, forsvinner medlemskapet og dermed tilgangen.

---

## 3. Beslutninger

Alle beslutninger er dokumentert med begrunnelse og hvor de endres. **Disse er
valgt for POC-fart — endre fritt.**

### B1 — To separate repoer

**Valgt:** to repoer, som oppgaven spesifiserer.

**Begrunnelse:** oppgaven sier det fire steder, og akseptansekriteriet "kan
løftes inn i LZ-repoet uten omskriving" forutsetter rene modulgrenser.

**Kostnad vi aksepterer:** ingen Terraform-graf på tvers, så Graph-propagering og
apply-rekkefølge må håndteres manuelt eller i CI. Mitigert med
`propagation_delay` og dokumentert rekkefølge.

**Endres i:** repo-struktur. Ved sammenslåing kan `depends_on` erstatte
ventetiden, og `propagation_delay` settes til `"0s"`.

### B2 — Eligibility tildeles statisk i tfvars, ikke via access package

**Valgt:** eligible-medlemmer listes i `roles[*].eligible_user_principal_names` i
dette repoet. Access packages i det andre repoet gir **aktivt** medlemskap
(`access_type = "Member"`).

**Begrunnelse — dette er den viktigste beslutningen i POC-en.** Oppgaven er
tvetydig om hvem som tildeler eligibility, og de to lesningene har ulike
lisenskrav:

| Lesning | Hvordan | Lisens |
|---|---|---|
| **A (valgt)** | Eligibility statisk i tfvars. Access packages dekker permanente roller. | **P2 holder** |
| B | Access package gir eligible medlemskap. Én forespørselsflate for alt. | Krever **Entra ID Governance / Suite** |

Microsoft dokumenterer at [tildeling av eligible gruppemedlemskap via access
packages](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-eligible)
krever Entra ID Governance- eller Entra Suite-lisens. POC-rammen utelukker
Governance-tillegg, så lesning B er ikke gjennomførbar som POC-en er satt opp.

Lesning A matcher også oppgavens testchecklist, der bare reader-eksempelet går
gjennom MyAccess, mens PIM-rollene aktiveres direkte.

**Konsekvens:** brukere blir ikke eligible via selvbetjening i POC-en. Eligibility
er en tfvars-endring. Det er en reell forskjell fra måldesignet og bør meldes
videre.

**Endres i:** `roles[*].eligible_user_principal_names` her, og
`access_type`-variabelen i det andre repoet (sett til `"EligibleMember"` for
lesning B). Begge er tfvars-endringer, ikke refaktorering.

### B3 — `approval_type` gjelder access-package-laget; PIM degraderer til ett steg

**Valgt:** `dual` gir **to godkjenningssteg** på access
package-forespørselen, og **ett steg med begge godkjennerne** på
PIM-aktiveringen.

**Begrunnelse:** de to lagene har ulike muligheter.

| Lag | Antall steg | Kilde |
|---|---|---|
| Access package-policy | opptil 2 | Microsoft dokumenterer [flerstegs godkjenning for access packages](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-approval-policy) |
| PIM for Groups-aktivering | 1 | `azuread_group_role_management_policy.activation_rules.approval_stage` finnes i entall |

Alternativene var å droppe `dual` helt (skjuler et krav) eller å gå til
`msgraph`/`azapi` mot beta-endepunkter for én verdis skyld (bryter provider-linjen
i oppgaven). Å implementere `dual` der plattformen støtter det, og degradere
eksplisitt og dokumentert der den ikke gjør det, gir mest verdi per innsats.

**Konsekvens:** oppgavens testpunkt "PIM-aktiver høyere rolle (owner) → dual
approval" må presiseres til å gjelde access-package-forespørselen.

**Mapping i dette repoet:**

| `approval_type` | PIM-godkjenning | Godkjennere i PIM |
|---|---|---|
| `self` | av | ingen |
| `team` | på | `approver_group_name` som `groupMembers` |
| `owner` | på | `systemeier` som `singleUser` |
| `dual` | på, ett steg | begge, én av dem signerer |

**Endres i:** `modules/azure-subscription-access/main.tf`, `local.approvers_by_role`.

### B4 — `azurerm` for RBAC, med deterministisk `name`

**Valgt:** `azurerm ~> 4.0` og `azurerm_role_assignment`, med
`name = uuidv5("url", "{scope}|{rolle}|{principal}")`.

**Begrunnelse:** `azurerm` er oppgavens spesifikasjon og den konvensjonelle
standarden, som gjør løft inn i LZ-repoet lettere. Deterministisk `name` bevarer
idempotency-egenskapen fra `azapi`-tilnærmingen: uten den genererer Azure en
tilfeldig GUID server-side og Terraform kan se falsk replace-on-drift.

**Endres i:** `modules/azure-rbac-on-group/main.tf`.

### B5 — Samme tfvars-skjema, egen fil per repo

**Valgt:** hvert repo har sin egen `terraform.tfvars`. Ikke delt fil.

**Begrunnelse:** oppgaven sier "samme struktur i begge repoer" — det er skjemaet
som er kontrakten, ikke fila. Delt fil via submodule eller tredje repo er for
tungt for POC-fase.

**Delvis overstyrt av M1 og M3 i `MALARKITEKTUR.md`.** Skjemaene divergerer nå
bevisst: dette repoet bruker `access_scopes` med `jit_mechanism` per rolle, mens
repo 2 trenger et eget begrep for kunde og prosjekt som mapper til et *sett*
gruppenavn. Kontrakten mellom repoene er derfor ikke lenger skjemaet, men
**gruppenavnene pluss `access_type`** — se outputene `group_names` og
`access_package_access_type`.

**Risiko:** divergens over tid. Et scope lagt til her men ikke der gir grupper
uten pakker.

**Endres i:** `terraform.tfvars` i begge repoer. Ved behov: legg en CI-jobb som
differ `terraform output group_names` mot gruppenavnene repo 2 slår opp.

### B6 — `display_name` og `mail_nickname` settes til samme streng

**Valgt:** begge attributtene settes til `azure-{sub}-{rolle}`. Oppslag i det
andre repoet skjer på `display_name`, som oppgaven spesifiserer.

**Begrunnelse:** `display_name` er ikke unikt i Entra, så oppslag på det alene er
sårbart for manuelle duplikater. `mail_nickname` er unik i tenant. Ved å sette
begge til samme streng beholder vi navnekontrakten uendret og får unikhetsvern
gratis. `prevent_duplicate_names = true` feiler tidlig ved kollisjon.

**Endres i:** `modules/entra-groups/main.tf`.

### B7 — Team-godkjennere angis eksplisitt per rolle

**Valgt:** nytt felt `approver_group_name` per rolle. Kreves når `approval_type`
er `team` eller `dual`. `owner` bruker `systemeier` fra subscription-nivå.

**Begrunnelse:** oppgaven nevner `"team"` som approval-type uten å definere hvem
team er. Eksplisitt felt er fleksibelt uten å være over-designet, og unngår å
gjenta systemeier to steder.

Gruppen må finnes fra før — POC-en oppretter den ikke.

**Endres i:** `variables.tf` (validering) og
`modules/azure-subscription-access/main.tf` (oppslag).

### B8 — `msgraph`-provideren brukes ikke

**Valgt:** kun `azuread`, `azurerm` og `time`.

**Begrunnelse:** oppgaven sier `azuread` dekker både PIM for Groups og access
packages med typede GA-ressurser. `msgraph` reserveres til dokumenterte
fallback-tilfeller.

### B9 — Gruppemedlemskap forvaltes utenfor `azuread_group`

**Valgt:** ingen `members`/`owners` på gruppe-ressursen. Separate
`azuread_group_member`/`azuread_group_owner`-ressurser, og `ignore_changes` på
begge attributtene.

**Begrunnelse:** access packages og PIM-aktivering legger til og fjerner medlemmer
utenfor Terraform. Med medlemslisten på gruppe-ressursen ville hver `plan` vist
drift og forsøkt å fjerne dem — som ville brutt akseptansekriteriet om at `plan`
skal vise "No changes".

**Endres i:** `modules/entra-groups/main.tf`.

### B10 — `assignable_to_role` er `false` som default

**Valgt:** default `false`, eksponert som variabel per rolle.

**Begrunnelse:** POC-en bruker gruppene til Azure RBAC, som ikke krever
role-assignable. `false` er minst privilegert. Men attributtet er force-replace,
så valget må tas riktig fra starten — se risiko R3.

**Endres i:** `roles[*].assignable_to_role` i tfvars.

---

## 4. Risikoer og ting å verifisere tidlig

### R1 — PIM-forvaltning av vanlige sikkerhetsgrupper (høyest usikkerhet)

**Gjelder bare `pim_for_groups`-stien (M3).** Etter M2 i `MALARKITEKTUR.md`
PIM-forvaltes ikke Azure-gruppene i det hele tatt — der ligger JIT i rolla, og
`azurerm_pim_eligible_role_assignment` treffer ARM, ikke gruppa. En konfigurasjon
med bare `azure_pim`-roller berøres derfor ikke av denne risikoen.

Grupper med `assignable_to_role = true` blir automatisk PIM-forvaltet. Vanlige
sikkerhetsgrupper må normalt "oppdages" av PIM først (portalen har en *Discover
groups*-flyt).

**Ukjent:** om `azuread_privileged_access_group_eligibility_schedule` eller
`azuread_group_role_management_policy` implisitt onboarder gruppen via Graph.
Dette er ikke verifisert.

**Verifiser først:** kjør `apply` på ett scope med én `pim_for_groups`-rolle og se
om policyen fester seg. Bruk et engangs-gruppenavn — PIM-forvaltning kan ikke
reverseres.

**Hvis det feiler:** sett `assignable_to_role = true` på PIM-rollene. Kostnaden er
at gruppen krever Privileged Role Administrator å forvalte og teller mot
tenant-grensen på role-assignable grupper.

### R2 — Argumentnavn: verifisert med `terraform validate` (løst)

`terraform init && terraform validate` er kjørt og gir **Success**. Det betyr at
alle ressurstyper, blokknavn og attributtnavn er sjekket mot providerens skjema —
inkludert `activation_rules`, `approval_stage`, `primary_approver` og feltene på
`azuread_privileged_access_group_eligibility_schedule`.

Én feil ble funnet og rettet under verifiseringen: `azuread_group_owner` finnes
ikke i provideren. Eiere settes i stedet via `owners`-attributtet på
`azuread_group`, med `null` når lista er tom slik at Entras standardoppsett ikke
overskrives.

**Gjenstår:** `validate` sjekker ikke verdier eller API-oppførsel. Ting som fortsatt
kan feile ved `apply`: gyldige verdikombinasjoner i `activation_rules`,
30-minutters-steg på `maximum_duration`, og konflikten mellom
`require_multifactor_authentication` og
`required_conditional_access_authentication_context` (vi setter bare den første).

### R3 — `assignable_to_role` er force-replace

Endring fra `false` til `true` sletter og gjenoppretter gruppen. Det river alle
RBAC-bindinger og PIM-policyer knyttet til den, og access-package-repoet peker
på en object-ID som ikke finnes lenger.

**Konsekvens:** ta valget før første `apply`. Skal det endres senere, kjør
`destroy`/`apply` på begge repoer i rekkefølge.

**Skjerpet av M4.** `entra_role`-sporet setter `assignable_to_role = true`
hardkodet, fordi Entra krever det for at en gruppe skal kunne bære en
directory-rolle. Det gir to nye fallgruver:

- En M2- eller M3-gruppe kan ikke gjenbrukes for M4, og omvendt.
- Å bytte `jit_mechanism` på en eksisterende rolle til eller fra `entra_role`
  sletter og gjenoppretter gruppa.

I M2 og M3 er attributtet `false` og forblir det, så der oppstår risikoen bare hvis
noen setter det manuelt.

### R4 — Graph-propagering

Nyopprettede grupper er ikke umiddelbart synlige for PIM-endepunkter eller for
`data "azuread_group"` i det andre repoet.

**Mitigert med:** `propagation_delay` (default 30s) i `pim-for-groups`, og
tilsvarende ventetid i access-package-repoet.

**Hvis første `apply` feiler med "not found":** kjør på nytt, eller øk
`propagation_delay`.

### R5 — PIM-forvaltning er irreversibel

Når en gruppe først er under PIM-forvaltning, kan den ikke tas ut igjen. Bruk
engangs-gruppenavn i POC-en, og regn med at test-grupper ikke kan gjenbrukes med
ren tilstand.

### R6 — Token-propagering ved aktivering

Etter PIM-aktivering oppdateres ikke eksisterende tokens. Gruppe-claim kommer
først ved neste token-utstedelse: portalen krever typisk 5-10 minutter eller
ut-/innlogging, CLI krever re-autentisering.

Dette er Entra-oppførsel, ikke en feil. Oppgavens testchecklist ber eksplisitt om
å måle denne forsinkelsen.

### R7 — PIM-policyen auto-importeres

Entra oppretter aktiveringspolicyen automatisk. Provideren importerer den ved
første bruk i stedet for å opprette den. Terraform overtar dermed eierskapet —
ikke endre policyen manuelt i portalen etterpå, det gir drift.

### R8 — Graph-permissions er den vanligste blokkeren

Se `README.md`. Kjør `./scripts/grant-graph-permissions.sh <app-id>` før første
`apply`.

---

## 5. Status

### Gjort

- Modulstruktur etter oppgavens spesifikasjon: `entra-groups`,
  `pim-for-groups`, `azure-rbac-on-group`, `azure-subscription-access`
- Composite `pim-group-access` for M3-stien, som wrapper `entra-groups` +
  `pim-for-groups`. `pim-for-groups` er dermed ikke lenger død kode.
- Rot-modul som dispatcher per rolle på `jit_mechanism`:
  `azure_pim` → `azure-subscription-access`, `pim_for_groups` →
  `pim-group-access`
- Variabelskjema `access_scopes` som dekker begge mekanismene, med validering som
  avviser felt som hører til den andre
- README per modul med input/output og kall-eksempel
- Script for Graph-permissions
- `.gitignore` som holder reelle subscription-IDer og UPN-er ute av git

### Verifisert

- `terraform fmt -recursive` — formatering normalisert
- `terraform init -backend=false` + `terraform validate` → **Success**. Alle
  ressurstyper og attributtnavn er sjekket mot provider-skjemaet.
- **Akseptansekriterium bekreftet:** de sky-agnostiske modulene init-er uten
  `azurerm`. Verifisert med `terraform providers` i hver modulmappe:

  ```
  entra-groups      → hashicorp/azuread
  pim-for-groups    → hashicorp/azuread, hashicorp/time
  pim-group-access  → hashicorp/azuread, hashicorp/time
  ```

  `pim-group-access` er composite-en hele M3-stien går gjennom, så kriteriet
  holder for stien og ikke bare for enkeltmoduler.

- **Discriminatoren er negativt testet.** Sju feilkonfigurasjoner avvises av
  variabelvalidering, blant dem `cloud = "aws"` sammen med
  `jit_mechanism = "azure_pim"` — som tidligere ga en gruppe med AWS-navn bundet
  til Azure RBAC, og som applyet rent.

- Provider-versjoner som ble resolvet: `azuread` 3.9.0, `time` 0.14.1
  (constraintene `~> 3.7` og `~> 0.12` tillater dette).

### Ikke gjort

- **Ingen `plan` eller `apply` mot POC-tenanten.** Krever autentisering og
  Graph-permissions.
- Ingen CI-workflow.
- Ingen backend-konfigurasjon (kjører med lokal state så langt).
- Idempotency ikke verifisert (`plan` etter `apply` skal vise "No changes").
- R1 (PIM-onboarding av vanlige sikkerhetsgrupper) ikke testet — dette er den
  største gjenstående usikkerheten.

### Neste steg, i rekkefølge

1. Grant Graph-permissions (se R8), eller sett directory-rollene på egen bruker
   for demo — se `FORUTSETNINGER.md`.
2. `apply` med **ett** scope og **én** `azure_pim`-rolle. Denne stien er den
   trygge: gruppene PIM-forvaltes ikke, så R1 er ikke i spill.
3. `plan` på nytt for å bekrefte idempotency.
4. `apply` med **én** `pim_for_groups`-rolle for å teste R1 tidlig. Bruk et
   engangs-gruppenavn — PIM-forvaltning er irreversibel.
5. Utvid til full tfvars med begge mekanismene.
6. Sett opp backend + CI når skjemaet er stabilt.

---

## 6. Åpne spørsmål til avklaring

- [ ] **Lesning A vs B for eligibility** (se B2). Avgjør om POC-en trenger
      Governance-lisens. Bør meldes til den som skrev oppgaven.
- [ ] **Testchecklisten** må justeres for at PIM-aktivering ikke støtter
      to-stegs godkjenning (se B3).
- [ ] **Hvilken gruppe er team-godkjennere?** `approver_group_name` er lagt til
      som felt, men POC-en definerer ikke en konkret gruppe (se B7).
- [ ] **Backend:** skal state ligge i samme storage account som det andre
      repoet, med ulik key?
- [ ] **Skal `dual` beholdes som verdi** når den degraderer på PIM-laget, eller
      bør POC-en heller bruke `owner` for PIM-roller og reservere `dual` til
      access-package-policyen?

---

## 7. For en ny chat-sesjon

Nyttig kontekst å gi opp front:

> Dette er vending-repoet (Oppgave 1) i en to-repo POC for access packages på
> Azure. Les `PROSJEKT-SAMMENDRAG.md` og `OPPGAVE.md` først. Koden er et
> uverifisert førsteutkast — ingen `terraform validate` er kjørt. Det andre
> repoet er `terraform-azuread-access-packages` og ligger som søskenmappe.

Filer som gir mest kontekst raskt:

| Fil | Hva den gir |
|---|---|
| `MALARKITEKTUR.md` | **måldesignet** — overstyrer beslutninger her. Les først. |
| `FORUTSETNINGER.md` | tilganger og lisenser per identitetstype. Les før `apply`. |
| `PROSJEKT-SAMMENDRAG.md` | denne fila — beslutninger, risikoer, status |
| `OPPGAVE.md` | full oppgavetekst for begge halvdeler |
| `variables.tf` | tfvars-kontrakten med validering |
| `modules/azure-subscription-access/main.tf` | der all logikk henger sammen |
| `README.md` | modultabell og kom-i-gang |
