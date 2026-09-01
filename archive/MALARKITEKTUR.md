# Målarkitektur — tilgangsstyring på tvers av skyer

**Status:** besluttet 17. august 2026. Overstyrer flere beslutninger i
`PROSJEKT-SAMMENDRAG.md` og bryter med deler av `OPPGAVE.md`. Se «Konflikter som
må avklares» nederst.

**Implementeringsstatus i dette repoet:**

| Beslutning | Status |
|---|---|
| M2 — Azure JIT på rollenivå | **implementert** som `jit_mechanism = "azure_pim"` |
| M2b — `permanent_access` per rolle | **implementert** |
| Én gruppe = ett tilgangsnivå = ett scope | **implementert** |
| M2-gruppene PIM-forvaltes ikke | **implementert** |
| M3 — øvrige skyer med `EligibleMember` | **delvis.** Entra-siden (gruppe + PIM-policy) er implementert som `jit_mechanism = "pim_for_groups"`. Koblingen til målskyen — SCIM-provisjonering og rollebinding på skysiden — er **ikke** i dette repoet. |
| Navnekonvensjon | **implementert** |
| M1 — én access package per kunde | hører til repo 2 |
| M4 — Entra directory-roller | **delvis.** Gruppe og rollebinding er implementert som `jit_mechanism = "entra_role"`. Aktiveringsreglene (MFA, godkjenning, varighet) kan **ikke** settes fra Terraform — se seksjonen nederst. |
| Access packages defineres ikke her | **implementert** ved at repoet ikke rører dem |

**Ingenting er noen gang `apply`-et.** Alt er verifisert med `validate` og mot
provider-skjemaet, ikke mot en levende tenant. Risiko R1 er derfor fortsatt åpen,
og den treffer nå bare M3-stien.

**Diagrammer.** Tegningene er på engelsk selv om dokumentasjonen er på norsk —
graphviz asciifiserte de norske tegnene («paa», «maa»), og engelsk gir lesbare
labels uten å måtte skrive rundt problemet.

- `generated-diagrams/target-architecture.png` — måldesignet i sin helhet, alle
  tre mekanismene og hvor governance-hullet i M4 sitter.
- `generated-diagrams/jit-mechanisms.png` — de tre JIT-mekanismene side om side,
  og hvor grensen mot skysiden og directory-planet går.
- `generated-diagrams/module-resource-graph.png` — modul- og ressursgrafen: hvilke
  ressurser hver mekanisme faktisk oppretter, og hvilken provider de hører til.

---

## Beslutningene

### M1 — Én access package per kunde

Access packages modelleres etter **kunde**, ikke etter ressurs.

Flere pakker per kunde når kunden er stor, har flere prosjekter, eller bruker
flere skyer. Ellers én.

**Begrunnelse.** Microsoft anbefaler eksplisitt at en access package inneholder
mer enn én resource role, og at pakkene modelleres etter avdeling, jobbfunksjon,
lokasjon eller prosjekt — ikke per ressurs
([ID Governance service limits](https://learn.microsoft.com/en-us/entra/id-governance/governance-service-limits)).

**Hva det løser.** Default-taket er 20 000 access packages og 25 000 assignment
policies per tenant. Med den gamle 1:1-modellen skalerte pakkene med
`subscriptions × roller`, som traff taket ved rundt 4 000 subscriptions. Nå
skalerer de med antall kunder og prosjekter.

```
gammel modell   500 sub × 5 roller  =  2 500 grupper,  2 500 pakker
M1              500 sub × 5 roller  =  2 500 grupper,  ~30 pakker
```

**Grupper er ikke flaskehalsen.** Det finnes ingen egen grense for antall
sikkerhetsgrupper. Taket er den delte objektkvoten i tenanten — 300 000 med
verifisert domene, delt med brukere, enheter, apper og service principals.

---

### M2 — Azure bruker RBAC JIT på spesifikke roller og spesifikke scope

På Azure gis tilgang som **eligible rolletildelinger** på rolle- og scope-nivå,
ikke som permanent RBAC med JIT-medlemskap i gruppa.

Brukeren aktiverer den enkelte rollen hen trenger, på det scopet hen trenger
den.

**Begrunnelse.** Granularitet ved aktivering. Én gruppe kan bære flere eligible
rolletildelinger på ulike scope, og brukeren velger. Gir også tilgang til
ABAC-betingelser på eligible tildelinger, som PIM for Groups ikke kan gi
([PIM for Azure resources](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-resource-roles-assign-roles)).

**Konsekvens:** Azure og de andre skyene bruker nå **to ulike mekanismer**.
Azure får rollenivå-JIT, øvrige skyer får medlemskaps-JIT (se M3). Premisset i
`OPPGAVE.md` om at PIM for Groups er «felles mekanisme på tvers» gjelder ikke
lenger for Azure. Det er et bevisst bytte: granularitet nå, mot en delt
mekanisme som Azure ikke trengte.

**Kjeden — AVGJORT:**

```
access package  →  medlemskap i sikkerhetsgruppe  →  JIT RBAC på rolle/scope
   (repo 2)              (aktivt medlemskap)          (eligible role assignment)
```

Principal på den eligible rolletildelingen er altså **gruppa**. Access packagen
gir aktivt gruppemedlemskap; JIT-en ligger i rollen, ikke i medlemskapet.
Microsoft dokumenterer mønsteret: gi gruppa en eligible rolletildeling, gjør
brukerne permanente medlemmer, og medlemmene aktiverer rollen
([Graph PIM-tutorial](https://learn.microsoft.com/graph/tutorial-assign-azureadroles?preserve-view=true&tabs=http)).

### Én gruppe = ett tilgangsnivå = ett scope

Navnekonvensjonen `azure-{sub}-{rolle}` har rolla i navnet, så hver gruppe bærer
nøyaktig én RBAC-rolle på ett subscription-scope. Ulike nivåer gis som ulike
grupper:

```
azure-{sub}-reader        → Reader      på /subscriptions/{id}
azure-{sub}-contributor   → Contributor på /subscriptions/{id}
azure-{sub}-owner         → Owner       på /subscriptions/{id}
```

Rolle-key og `azure_role` er frie strenger — `reader`/`contributor`/`owner` er
eksempler, ikke et definert sett. Ingen modulkode special-caser rollenavn.

Gruppetallet blir dermed `subscriptions × roller`. Det er greit: grupper er ikke
flaskehalsen, access packages er, og M1 løser det. Trenger en jobbfunksjon flere
roller samtidig, bundles det i access package-laget — ikke ved å legge flere
roller på én gruppe.

**Vurdert og forkastet: generisk gruppe med flere roller.** Ville spart objekter
vi har rikelig av, og betalt med at gruppenavnet slutter å beskrive tilgangen,
at `permanent_access` må flyttes fra gruppe til rollebinding, og at Azure får en
annen gruppemodell enn AWS — der 1:1 mot permission set er påkrevd uansett.

### M2-gruppene PIM-forvaltes IKKE

En M2-gruppe gjør nøyaktig to ting, og ingenting mer:

1. gir medlemmene mulighet til å **gi seg selv** den rolla gruppa representerer —
   aktivere den eligible rolletildelingen, eller
2. gi **permanent tilgang** til den rolla når `permanent_access = true` (se M2b).

Medlemskapet er aktivt, ikke just-in-time. Gruppa er en ren RBAC-principal uten
`azuread_group_role_management_policy` og uten eligibility schedules.

**Konsekvens:** R1 gater bare M3. Azure-sporet kan bygges uten å vite om PIM
onboarder vanlige sikkerhetsgrupper, siden det ikke trenger PIM for Groups i det
hele tatt.

---

### M2b — `permanent_access`, én bool per rolle

Ikke all tilgang bør være JIT. Reader er det opplagte eksempelet: aktivering hver
gang for lesetilgang er friksjon uten sikkerhetsgevinst av betydning, og
token-propagering (R6) gjør det ekstra irriterende.

```hcl
"reader" = {
  azure_role       = "Reader"
  permanent_access = true       # permanent azurerm_role_assignment
}

"contributor" = {
  azure_role           = "Contributor"
  permanent_access     = false  # default — eligible, må aktiveres
  approval_type        = "team"
  max_activation_hours = 8
}
```

| `permanent_access` | Ressurser | Brukeropplevelse |
|---|---|---|
| `false` *(default)* | `azurerm_pim_eligible_role_assignment` + `azurerm_role_management_policy` | må aktivere rolla, tidsbegrenset |
| `true` | `azurerm_role_assignment` | tilgang så lenge hen er medlem av gruppa |

Default er `false`, altså JIT — det sikre valget. Permanent tilgang er noe du
aktivt slår på.

Tidsbegrensningen for `permanent_access = true` kommer fra **expiry på access
package-tildelingen** i repo 2, ikke fra RBAC. Det er samme substitutt for access
reviews som `OPPGAVE.md` beskriver.

**Dette løser konflikten med akseptansekriteriet.** Oppgaven krever at
permanent-rollen har permanent gruppemedlemskap mens PIM-rollene har
eligible-tilgang. Med `permanent_access = true` på reader er begge sporene på
plass, og kriteriet kan oppfylles uten å endre oppgaveteksten.

**`permanent_access = false` krever TO ressurser** som `OPPGAVE.md` forbyr, ikke
én:

- `azurerm_pim_eligible_role_assignment` — gjør tildelingen eligible
- `azurerm_role_management_policy` — setter aktiveringsreglene: MFA, godkjenning,
  varighet

Uten den andre får du eligible tildelinger med Azures standardpolicy — altså
uten MFA og uten godkjenning. Det er ikke et halvt kompromiss, det er en
tilgangsmodell uten kontrollene du tror du har.

### Verifiserte begrensninger i azurerm-laget

Sjekket mot provider-skjemaet i azurerm 4.81.0, ikke antatt:

- **Aktiveringspolicyen er nøklet på (scope, rolle)** — ikke per gruppe. To
  eligible roller kan derfor ikke ha samme `azure_role` på samme subscription.
  Validering fanger det.
- **Kun ETT `approval_stage`** er tillatt. `dual` gir begge godkjennerne i samme
  steg, der én signerer. Samme degradering som i `azuread`-laget, så B3 gjelder
  uendret.
- **`primary_approver.type` er `"User"` eller `"Group"`** — ikke `singleUser` og
  `groupMembers` som i `azuread`. Lett felle ved portering av kode mellom lagene.
- **`role_definition_id` kreves**, ikke rollenavn. Modulen slår opp med
  `data "azurerm_role_definition"`.
- **`azurerm_pim_eligible_role_assignment` har ingen `name`**, så
  `uuidv5`-grepet mot falsk replace-on-drift gjelder bare permanente bindinger.

---

### M3 — Øvrige skyer: gruppe per (leverandør, prosjekt, tilgangsnivå)

For alle skytjenester der Entra er kilde til autentisering og autorisasjon —
AWS, GCP, GitHub — er inputen tre verdier:

```
leverandør  +  prosjekt  +  tilgangsnivå   →   én Entra-gruppe
```

Gruppa kobles deretter til skyens autorisasjonsmekanisme: AWS permission set,
GCP IAM binding, GitHub team-rolle.

**Begrunnelse.** For AWS finnes det ikke noe alternativ. Det er ingen native PIM
i AWS og ingen «eligible permission set» å aktivere. AWS' eget dokumenterte
mønster for JIT mot AWS er nøyaktig dette: Entra-sikkerhetsgruppe, PIM for
Groups på medlemskapet, SCIM-synk til IAM Identity Center, gruppe mappet til
permission set
([AWS Security Blog, juni 2025](https://aws.amazon.com/blogs/security/implementing-just-in-time-privileged-access-to-aws-with-microsoft-entra-and-aws-iam-identity-center)).

**Kjeden — AVGJORT. Én gruppe, ingen nesting.**

```
access package                     gruppe                aktivering        SCIM         skyen
access_type =         →      aws-{konto}-{rolle}    →   PIM for Groups  →  synk  →  permission set
"EligibleMember"             gcp-{prosjekt}-{rolle}     MFA/godkjenning            IAM binding
   (repo 2)                     (repo 1)                                          team-rolle
```

Access packagen gir **eligible** medlemskap direkte. Brukeren har ingen stående
tilgang, må aktivere, og aktiveringen er tidsbegrenset etter PIM-policyen som
repo 1 setter på gruppa.

**Slik konfigureres det i dette repoet.** Per rolle i `access_scopes`:

```hcl
"prod-konto" = {
  cloud      = "aws"
  scope_id   = "419276583014"   # dokumentasjon, ingen ressurs binder den
  systemeier = "ola@kunde.no"

  roles = {
    "admin" = {
      jit_mechanism = "pim_for_groups"
      target_role   = "AdministratorAccess"

      approval_type        = "owner"
      max_activation_hours = 8
      require_mfa          = true
    }
  }
}
```

Rot-modulen dispatcher til `pim-group-access`, som wrapper `entra-groups` og
`pim-for-groups`. Composite-en deklarerer ikke `azurerm` — hele M3-stien kjører
uten Azure Resource Manager.

**Hva som IKKE er dekket av repoet.** Bare de to første leddene i kjeden over.
SCIM-synken og koblingen gruppe → permission set / IAM binding / team-rolle skjer
på skysiden og er utenfor dette repoet. `target_role` og `scope_id` finnes for å
dokumentere hva koblingen skal være; `terraform output target_cloud_bindings` gir
arbeidslisten.

Praktisk konsekvens som er verdt å ta inn: fram til den koblingen er satt opp gir
gruppa ingen faktisk tilgang. En aktivering vil se ut som den lykkes i PIM, uten
at noe endrer seg i AWS.

### Forkastet: to-gruppe-modell med nesting

Alternativet var at access packagen ga aktivt medlemskap i en gruppe A, som var
eligible medlem av gruppe B. Forkastet av to grunner, begge tunge:

**SCIM ser ikke nestede medlemmer.** Entras provisioneringstjeneste leser og
provisionerer kun brukere som er *umiddelbare* medlemmer av gruppa som er tildelt
SCIM-appen. Det samme følger av at nesting ikke støttes for app role assignment,
«for både access og provisioning»
([Entra service limits](https://learn.microsoft.com/en-us/entra/identity/users/directory-service-limits-restrictions),
[WorkOS om Entra nested groups og SCIM](https://workos.com/blog/azure-entra-nested-groups-directory-sync)).
Om PIM-aktivering gir umiddelbart eller transitivt medlemskap var uavklart, og
svaret var for løsbærende å gjette på.

**Uklart om Terraform kan gjøre det.** Ingen bekreftelse på at
`azuread_privileged_access_group_eligibility_schedule.principal_id` aksepterer en
**gruppes** object-ID — alle eksempler bruker brukere. Kravet om at alt skal
deployes via Terraform kunne dermed utelukket modellen uansett.

Ett-gruppe-modellen fjerner begge risikoene og gir samme sluttresultat. Skulle
gruppe A senere vise seg nødvendig — for eksempel for gjenbruk på tvers av flere
skygrupper — må begge risikoene testes først.

### Konsekvens for repo 2: `access_type` må settes PER GRUPPE

De to sporene trenger ulik `access_type` på samme access package:

| Spor | `access_type` | Hvor ligger JIT |
|---|---|---|
| Azure (M2) | `Member` | i rolla — eligible role assignment |
| Andre skyer (M3) | `EligibleMember` | i medlemskapet — PIM for Groups |

Merk at Azure bruker `Member` også for roller med `permanent_access = false` —
medlemskapet skal være aktivt uansett, siden det er *rolla* som aktiveres.

Siden M1 gir én pakke per kunde, vil samme pakke typisk inneholde begge typer.
Det er mulig: i `azuread`-provideren settes `access_type` på
`azuread_access_package_resource_package_association`, altså per resource role —
ikke per pakke. Repo 2 må derfor eksponere det per gruppe, ikke som én global
innstilling.

### Krav og forutsetningar

- **Governance- eller Suite-lisens.** Kreves for å tildele eligible
  gruppemedlemskap via access package
  ([Microsoft Learn](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-eligible)).
  Bekreftet på plass.
- **Gruppa må vere PIM-forvalta.** Utan det finst det ingen eligibility å tildele.
  Dette er R1, framleis uverifisert, og gatar heile M3.
- Gruppene må vere direkte tildelte sikkerheitsgrupper oppretta i Entra.
  Dynamiske grupper og grupper synkronisert frå on-prem AD kan ikkje brukast med
  PIM for Groups.
- Flat gruppestruktur følgjer no automatisk av modellen — ikkje lenger ei regel
  som må handhevast.

**Fallgruve på AWS — tilgangsvinduet er ikke det du tror.** Tre varigheter
virker samtidig og termineres ikke av hverandre: AWS access portal-sesjonen
(default 8t), permission set-sesjonen (default og minimum 1t, maks 12t), og
PIM-aktiveringen (default 8t, 30 min–24t). AWS' eget regneeksempel gir opptil
**tre timer** faktisk tilgang med 8t + 1t + 1t. Det kan i tillegg ta opptil en
time før applikasjonstilgangen faktisk forsvinner.

`max_activation_hours` betyr altså ikke det samme på Azure som på AWS. Det må
dokumenteres i modulene, ellers vil noen tro at `2` betyr to timer overalt.

**SCIM-latens:** medlemskapsendringer synkes typisk på 2–10 minutter, men kan
falle tilbake til 40-minutters-intervallet ved PIM-throttling. Uverifisert hvor
mange samtidige aktiveringer som utløser throttling — verdt å teste før skala.

---

### M4 — Entra directory-roller

**Status: delvis implementert.** `jit_mechanism = "entra_role"`.

Gruppa gjøres role-assignable og bindes til en directory-rolle. Kjeden er kortere
enn i M2 og M3 fordi det ikke finnes noe skysideledd:

```
access package  →  medlemskap i gruppe  →  Entra directory-rolle
   (repo 2)            (AKTIVT)            (permanent eller eligible)
```

Konfigureres slik:

```hcl
"tenant" = {
  cloud      = "entra"
  scope_id   = "/"          # directory_scope_id, "/" er hele tenanten
  systemeier = "ola@kunde.no"

  roles = {
    "groupsadmin" = {
      jit_mechanism = "entra_role"
      entra_role    = "Groups Administrator"
    }
  }
}
```

### Terraform kan ikke styre aktiveringen

Dette er den viktigste begrensningen i M4, og den er en providerbegrensning, ikke
et designvalg.

`azuread` har ingen policy-ressurs for directory-roller.
`azuread_group_role_management_policy` tar `group_id` og gjelder *grupper*. Det
finnes ingen `azuread_directory_role_management_policy`. MFA, godkjenning, maks
aktiveringsvarighet og begrunnelseskrav må derfor settes i PIM-portalen.

Følgen for konfigurasjonen: `approval_type`,
`max_activation_hours`, `require_mfa`, `require_justification` og
`require_ticket_info` **avvises** av valideringen for `entra_role`. Alternativet
ville vært å ta dem imot og ignorere dem, altså la konfigurasjonen hevde at MFA
er påkrevd uten at det er sant.

For å gjøre hullet synlig i plan og output, ikke bare i dokumentasjonen, finnes
`terraform output entra_activation_governance_gap`.

Dette er grunnen til at aktiveringsfeltene i `access_scopes` har `null` som
default i stedet for konkrete verdier: uten det kunne ikke valideringen skille
«ikke satt» fra «satt til defaulten». M2 og M3 får defaultene sine i rot-modulen.

### Scope-begrepet

Directory-roller er tenantglobale, eller avgrenset til en administrative unit.
Det finnes ingen subscription å henge dem på. `scope_id` tolkes derfor som Graph
sin `directory_scope_id`:

```
"/"                            hele tenanten
"/administrativeUnits/<guid>"  avgrenset
```

Navnekonvensjonen beholdes uendret, med `cloud = "entra"` og en scope-nøkkel som
beskriver avgrensningen — `entra-tenant-groupsadmin`. Ikke alle directory-roller
kan avgrenses til en administrative unit, og Graph avviser kombinasjonen ved
apply, ikke ved plan.

### Eligibility kan ikke utløpe

`azuread_directory_role_eligibility_schedule_request` har ingen `schedule`-blokk.
Eligibility er permanent, og det er ikke valgbart. Livssyklusen må styres av
expiry på access package-tildelingen i repo 2. Det skiller seg fra M2, der
`eligible_duration_days` finnes.

### `assignable_to_role` gjør M4-grupper irreversible

Entra krever at gruppa er role-assignable for å bære en directory-rolle, så
modulen setter det uten å spørre. Attributtet er force-replace, og det betyr:

- M2- og M3-grupper kan ikke gjenbrukes for M4
- å bytte mekanisme på en eksisterende rolle sletter og gjenoppretter gruppa,
  river rollebindingene og etterlater repo 2 pekende på en object-ID som ikke
  finnes

Risiko R3 treffer derfor hardere her enn i M2 og M3, der attributtet er `false`
og forblir det.

### Graph-permissions

Utover M2 og M3:

```
RoleManagement.ReadWrite.Directory
RoleEligibilitySchedule.ReadWrite.Directory
```

`RoleManagement.ReadWrite.Directory` lar service principal-en tildele
directory-roller i hele tenanten. Som M3 kan ikke M4 kjøres med `az login` som
bruker — Azure CLI sin app er ikke pre-autorisert for scopene.

---

## Avgrensning — access packages defineres ikke i vending-repoet

Vending-repoet oppretter grupper og kobler dem til skyens autorisasjon. Det er
alt.

Access packages, kataloger, request-policyer og godkjenningsflyt hører i
access-package-modulen (repo 2).

**Konsekvens for kontrakten:** repo 2 kan ikke lenger generere pakker mekanisk
fra `subscriptions × roles`. Den trenger et eget begrep for kunde og prosjekt
som mapper til et **sett** gruppenavn. Det bryter kravet i `OPPGAVE.md` om
«samme tfvars-struktur i begge repoer» — skjemaene divergerer bevisst, fordi de
to lagene nå modellerer ulike ting.

---

## Navnekonvensjon — AVGJORT

`azure-{sub}-{rolle}` beholdes, og **samme mønster gjelder alle leverandører**
som prefiksbytte:

```
azure-{subscription}-{rolle}
aws-{konto}-{rolle}
gcp-{prosjekt}-{rolle}
github-{org}-{rolle}
```

Dette er ingen endring — `OPPGAVE.md` beskriver allerede generaliseringen
(«På andre skyer blir det aws-{konto}-{rolle} osv. — samme prinsipp, annet
prefiks»). Konflikten jeg tidligere flagget mot navnekontrakten faller bort.

`cloud_prefix`-variabelen i dagens kode er allerede bygget for dette, med
validering på små bokstaver og tall uten bindestrek.

*Behold grepet fra B6:* `display_name` er ikke unikt i Entra, `mail_nickname` er.
Sett begge til samme streng, så gir navnekontrakten kollisjonsvern gratis.

---

## Konflikter som må avklares med oppgaveforfatter

1. **`azurerm_pim_eligible_role_assignment` OG `azurerm_role_management_policy` er
   eksplisitt forbudt** i `OPPGAVE.md` under «skal ikke gjenbrukes». M2 krever
   begge — den første for eligibility, den andre for aktiveringsreglene.
   Oppgaven avviser dem fordi de er PIM for Resources; M2 velger dem bevisst.
   **Dette er den eneste gjenstående spec-konflikten som må avklares med
   oppgaveforfatter.**
2. **«Felles mekanisme på tvers»** gjelder ikke lenger for Azure etter M2.
   Azure får rollenivå-JIT, øvrige skyer medlemskaps-JIT.
3. **«Samme tfvars-struktur i begge repoer»** brytes av M1 og M4.

**Løst:** akseptansekriteriet om permanent reader — se M2b. Bool-en `jit = false`
gir permanent RBAC på gruppa, så både det permanente og det JIT-baserte sporet
finnes. Kriteriet kan oppfylles uten å endre oppgaveteksten.

**Ikke i konflikt:** navnekontrakten — se avgjort seksjon over.

Punkt 1 er verdt å merke seg spesielt: den eksisterende interne modulen
`bouvettl/terraform-azurerm-rbac-groups` er allerede bygget på rollenivå-JIT.
`OPPGAVE.md` kaller det «feil PIM-modell» for denne POC-en. M2 gir den modellen
rett. Noen bør avgjøre hvilken som er organisasjonens standard, siden begge nå
er i drift.

---

## Hva som ikke er besluttet

- Hvordan tilgangsnivå defineres per leverandør — fri streng, eller et definert
  sett. Dagens kode bruker fri streng, som `OPPGAVE.md` krever.
- Om `jit = false` også skal være mulig på M3-grupper, eller om andre skyer alltid
  er JIT. Ikke diskutert.
- Om `assignable_to_role` må settes. Avhenger fortsatt av R1: om PIM onboarder
  vanlige sikkerhetsgrupper implisitt. Ikke verifisert. Attributtet er
  force-replace, så valget må tas før første apply.

  *Svakt indisium i riktig retning:* en provider-issue viser at
  `azuread_privileged_access_group_eligibility_schedule` feiler med
  `RoleAssignmentRequestPolicyValidationFailed` når group role management policy
  mangler ([issue #1450](https://github.com/hashicorp/terraform-provider-azuread/issues/1450)).
  Det tyder på at policy-ressursen faktisk etablerer PIM-forvaltningen. Dagens
  kode har allerede `depends_on` i riktig retning. Fortsatt ikke bevis.

---

## Testrekkefølge før noe bygges

1. **R1 — gatar M3.** `apply` én gruppe med PIM-policy. Fester policyen seg på en
   vanlig sikkerhetsgruppe, eller må den «Discover groups»-flyten kjøres manuelt?
   Avgjør samtidig `assignable_to_role`, som er force-replace og derfor må settes
   riktig før første apply.
2. **`EligibleMember` ende-til-ende.** Access package i repo 2 → eligible
   medlemskap → aktivering → medlemskap. Bekrefter at Governance-lisensen dekker
   det vi tror, og at `access_type` per resource role fungerer som antatt.
3. **Når AWS-spoken bygges:** mål faktisk tilgangsvindu med sesjonsstabling, og
   SCIM-latens under samtidige aktiveringer.

Steg 1 er det eneste som blokkerer. Steg 2 kan kjøres parallelt med at modulene
skrives om, siden det ikke påvirker gruppestrukturen.

---

*Kildeinnhold er omskrevet for å overholde lisensvilkår. Alle grenser og
tekniske påstander er verifisert mot lenkede kilder 17. august 2026.*
