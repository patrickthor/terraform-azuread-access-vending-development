# Fagleg gjennomgang, runde 2

Tre agentar, uavhengig av kvarandre: Terraform/IaC, dokumentasjon og Entra ID.
`archive/` var utanfor scope for alle tre. Ingen filer er endra.

Bakgrunn: repoet har vore applyet og deretter destroya. State har serial 299 og
null ressursar, tenanten ingen grupper. Endringar er gratis no.

Agentdefinisjonane ligg i `.kiro/agents/` og er oppdaterte for denne repoforma.

---

## Tre nye funn som ikkje var med i runde 1

### N1 — M4 gir kontroll over M2 og M3 (KRITISK)

`terraform.tfvars:319-341`, `modules/entra-role-access/main.tf:181-211`

Konfigurasjonen vender `Groups Administrator` på `"/"`. Den rolla har
`microsoft.directory/groups/members/update`, som gjeld alle grupper **unnateke**
role-assignable. Alle M2- og M3-grupper er `assignable_to_role = false`.

Konsekvens: ein som aktiverer `entra-tenant-groupsadmin` kan

- legge seg sjølv inn som **aktivt** medlem i `azure-tommer-readingbooks`
  (permanent Reader), `azure-morkanaught-blob-leser` (`self`) og
  `aws-jaws-readonly` (`self`) — utan access package, utan godkjenning
- **skrive om aktiveringspolicyen** på M3-gruppene, fordi PIM-policy for
  ikkje-role-assignable grupper kan forvaltast av `Groups Administrator`. Fjerne
  MFA-kravet på `aws-jaws-admin`, fjerne godkjenningskravet. Terraform ser det
  ikkje før neste plan, og for attributta modulen ikkje set: aldri.

Kjelder: [custom-group-permissions](https://learn.microsoft.com/entra/identity/role-based-access-control/custom-group-permissions#update-members-of-different-group-types),
[groups-role-settings](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/groups-role-settings)

Dette er ikkje teoretisk komposisjon — dei tre mekanismane lever i same tenant, i
same rot-modul, under same access package-lag. `entra_role` er mekanismen Terraform
har **minst** kontroll over, og det er den som deler ut makta over dei to andre.
Ingenting i README, tfvars eller modul-README nemner koblinga.

### N2 — «Ingen eiere» er ikkje mogleg

`main.tf:47-53`, `modules/entra-groups/main.tf:50-54`

Provideren er eksplisitt: *«By default, the principal being used to execute
Terraform is assigned as the sole owner. Groups cannot be created with no owners or
have all their owners removed.»*
([azuread_group](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/group))

Kommentaren i `main.tf:50-51` — «Godkjennere skal aldri kunne omgå vendingen selv.
Ingen faste medlemmer, ingen eiere» — er derfor feil på andre halvdel.
Godkjennargruppa **får** ein eigar, og den eigaren kan legge medlemmar i
godkjennargruppa, altså dele ut godkjenningsrett utanfor vendinga. Det er presis
den omgåinga kommentaren seier han hindrar.

Verre: køyrer du apply frå ein brukarkonto — som er stien `README.md:186-200`
beskriv — blir **eitt menneske eineeigar av samtlege grupper**, inkludert dei
role-assignable M4-gruppene. Ein eigar av ei role-assignable gruppe kan legge til
medlemmar direkte, og for `directoryreader` (permanent) er tilgangen umiddelbar.

Sikkerheitseigenskapen til løysinga avheng altså av *kva identitet som køyrer
Terraform*, og det står ingen stad.

### N3 — Outputet «Effektive aktiveringsregler» er input, ikkje effektive verdiar

`outputs.tf:155-172`, `modules/azure-rbac-on-group/outputs.tf:43-56`,
`modules/pim-for-groups/outputs.tf:19-33`

Verdiane byggjast av `var.*`, formatert som ISO8601 og talt opp. Dei blir ikkje
lest frå ressursen. Beskrivinga seier «Effektive aktiveringsregler … for
verifisering mot testchecklisten».

Det er nøyaktig dei attributta som *kan* bli overstyrte av tenantverdiar som
outputet later som at det stadfestar. Kombinasjonen — Optional+Computed pluss eit
output som ekkoar input under namnet «effektiv» — produserer falsk tryggleik i det
som er meint å vere verifiseringssteget.

Fiks: les frå ressursattributta, eller døyp om til `requested_activation_settings`.

---

## Korrigering av runde 1

Eg sa at sentinelen `"permanent"` døydde fordi defaultane er triplisert i tre lag.
Det var upresist. IaC-agenten testa dei to hoppa separat:

| Mottakar | Eksplisitt `null` |
| --- | --- |
| `optional(string, "P30D")` i objekt-attributt (`pim-group-access`) | **erstattast av `"P30D"`** |
| vanleg `variable` med `default = "P30D"` (`pim-for-groups`) | **passerer gjennom som `null`** |

Det er altså `optional()` i `pim-group-access/variables.tf:106` som drep han, ikkje
variabel-defaulten i `pim-for-groups`. Praktisk: å fjerne `"P30D"` frå `optional()`
og la defaulten bu i rota — som repoet gjer for alle andre felt — reparerer hopp 1.

**Men det er ikkje nok.** `expire_after` er Optional+Computed, så `null` betyr
«ikkje i konfigurasjonen» — provideren sender ingen verdi og tenantverdien står.
`null` kan **setje** ei grense, aldri **fjerne** ei. Sentinelen krev derfor at
`expiration_required` settast eksplisitt.

Søstermodulen gjer det alt riktig, `modules/azure-rbac-on-group/main.tf:138-141`:

```hcl
eligible_assignment_rules {
  expiration_required = each.value.eligible_duration_days != null
  expire_after        = each.value.eligible_duration_days != null ? "P${each.value.eligible_duration_days}D" : null
}
```

Same mønster, same provider-semantikk, to ulike modenheitsnivå i same repo.

---

## Modul-klarheit — svaret på runden

IaC-agenten gir ei konkret liste. Kjernepoenget først:

**«Kallbar modul» og «kalla med ein tfvars-fil» er to ulike ting.**
`terraform.tfvars` blir berre lest av ein rotmodul. Blir dette ein barnemodul, får
kallaren HCL-argument, ikkje tfvars.

Løysinga er to lag:

```
modules/access-vending/     <- rendyrka modul, ingen provider-blokker
examples/complete/          <- rotmodul: providere, tenant_id, backend, terraform.tfvars
```

Då fungerer begge bruksmåtane, og verifiseringsflyten i README held.

### Kva som konkret må endrast

| # | Endring | Kvar |
| --- | --- | --- |
| B1 | `provider`-blokkene må bort | `providers.tf:1-12` |
| B2 | `variable "tenant_id"` må bort — einaste bruk er `providers.tf:2` | `variables.tf:1-4` |
| B3 | `variable "provider_subscription_id"` må bort — einaste bruk er `providers.tf:11` | `variables.tf:6-17` |
| B4 | `versions.tf` deklarerer `azurerm` som rota **ikkje** brukar direkte, og utelèt `time` som konfigurasjonen **krev** | `versions.tf:3-19` |

Ein modul med eigne provider-blokker er *legacy shared module*: modulblokka kan
ikkje bruke `count`, `for_each` eller `depends_on`, og ressursane kan ikkje
fjernast reint fordi provider-konfigurasjonen forsvinn samtidig med dei siste
ressursane.

B3 er verst i dag: variabelen er påkravd utan default, så ein rein AWS-brukar må
oppgi ein Azure subscription-GUID for å komme til plan. Det forsvinn av seg sjølv
når provider-blokka gjer det.

Rota brukar berre `azuread` direkte, via `data "azuread_group" "scope_approvers"`
(`main.tf:200-203`). `azurerm` er der berre fordi `providers.tf` konfigurerer han.

---

## Verifisert av agentane

| Påstand | Metode | Resultat |
| --- | --- | --- |
| Sentinelen gir `P30D` | isolert `/tmp`-prosjekt med identisk uttrykk og mottakartype | sentinel og utelate felt er umogleg å skilje |
| `optional()` mot vanleg `default` | tre kall: `null`, utelate, `"P90D"` | `optional()` et `null`; variabel-default gjer det ikkje |
| Sentinelen i faktisk oppsett | `terraform console` på repo-kopi | `...["billing"].active_assignment_expire_after == null` → `true` |
| Alle policy-attributt er Optional+Computed | `providers schema -json` | samtlege i `activation_rules`, `active_assignment_rules`, `eligible_assignment_rules`, begge providerar |
| `approval_stage` tillèt eitt steg | same dump | `max_items = 1` begge providerar, `primary_approver` er set utan max |
| Kryssvariabel-refs krev TF 1.9 | grep + HashiCorp-dok | 4 stader i 3 filer; alle `versions.tf` seier `>= 1.5` |
| `tenant_id`/`provider_subscription_id` berre til providere | grep over alle `.tf` | eitt treff kvar, begge i `providers.tf` |
| Rota brukar ikkje `azurerm` direkte | lesing av `main.tf` | berre `data "azuread_group"` + modulkall |
| Rot-lockfila manglar på disk | `git status` | ` D .terraform.lock.hcl` — sporet i git, sletta i arbeidstreet |
| `merge([]...)` med tomt `access_scopes` | console + isolert plan | `{}`, ingen feil — mistanken var ubegrunna |

---

## Terraform — resten

### Reelle feil

- **F3** `required_version = ">= 1.5"` i alle `versions.tf`. Kryssvariabel-refs i
  `validation` på `variables.tf:284`, `:415`,
  `modules/azure-subscription-access/variables.tf:99`,
  `modules/pim-group-access/variables.tf:134`. På 1.5–1.8 feiler koden med
  `Invalid reference in variable validation` før noko anna skjer.

### Risiko

- **R1** `owners` kan leggast til, aldri fjernast. Flippar nokon
  `set_systemeier_as_group_owner` frå `true` til `false`, blir eigarane ståande og
  planen viser ingenting. Den eine bryteren repoet åtvarar sterkast mot, er einvegs.
- **R3** `eligible_assignment_rules.expire_after` settast aldri i `pim-for-groups`.
  Set nokon `eligible_assignment_expiration_required = true`, kjem varigheita frå
  tenanten. Ingen variabel finst.
- **R4** `required_conditional_access_authentication_context` er umanagert i begge
  policy-ressursane. Ein tenantadmin kan setje eit auth context-krav utan at
  Terraform viser det. Same kategori som M4-hòlet, men udokumentert.
- **R6** `assignable_to_role` blir stille overstyrt for `entra_role`. Skriv du
  `false`, blir det `true` (`modules/entra-role-access/main.tf:145`). Sjette
  mekanisme-spesifikke felt blir avvist; dette blir ignorert.
- **R7** **Ingen validering mot at to scope brukar same `entra_role`.**
  `local.requested_role_names` dedupliserer innanfor eitt scope. To scope med
  `"Groups Administrator"` gir to `azuread_directory_role`-ressursar for det same
  tenantglobale objektet. Fjernast det eine scopet, kan rolla bli deaktivert under
  det andre. Same klasse som `azurerm_role_management_policy`-kollisjonen, som ER
  validert grundig.
- **R9** `access_package_access_type` finst i to inkonsistente utgåver.
  `modules/pim-group-access/outputs.tf:23` og
  `modules/entra-role-access/outputs.tf:29` blir aldri konsumerte;
  `azure-subscription-access` har det ikkje i det heile. Dette er den kontrakten
  README peikar på som «outputet gir det direkte så repo 2 ikkje må utleie det sjølv».
- **R10** Rot-lockfila er sletta i arbeidstreet. Providerversjonar er upinna;
  `~> 3.7` og `~> 4.0` gjer nye minor-versjonar fritt vilt mellom to køyringar.
  `.gitignore` seier samtidig at ho SKAL committast.
- **R12** Gruppenamn-kollisjon fangast først ved apply. Scope `a` + rolle `b-c` og
  scope `a-b` + rolle `c` gir begge `azure-a-b-c`. `--`-valideringa vernar
  composite-nøkkelen i outputs, ikkje gruppenamnet. Ei validering på tvers av alle
  genererte namn — inkludert `{cloud}-{scope}-approvers` — flyttar det til plan-tid.

### Stil

- **S1** `ignore_changes = [members]` er ein no-op. `members` er Optional+Computed
  og settast ikkje av modulen, så eit attributt utanfor konfigurasjonen gir alt
  ingen drift. Behald for lesbarheit, men kommentaren bør seie at det er
  dokumentasjon, ikkje mekanikk.
- **S2** Daud kode: `local.unresolved_role_names`,
  `modules/entra-role-access/main.tf:79-82`.
- **S5** Er `pim-for-groups` som eigen modul verdt det? Han handterer éi gruppe, har
  ingen annan kallar, og heile grensesnittet er å pakke ut ei rolle til flate
  variablar. Prisen er reell: `active_assignment_expire_after` går gjennom to
  typekonverteringar med to ulike default-mekanismar, og det er nøyaktig der F1 bur.
- **S8** `terraform.tfvars.example`: 431 kommentarlinjer mot 58 kodelinjer.
- **S9** `access_model`-beskrivinga nemner ikkje M4, men merger inn M4-verdiar.

---

## Entra ID — resten

### Høg

- **H1/H2** `active_assignment_rules`: M3 set `expire_after` utan
  `expiration_required`; **M2 forvaltar blokka ikkje i det heile**
  (`modules/azure-rbac-on-group/main.tf:91-150`). Fem attributt, alle
  Optional+Computed. Reglane for aktive tildelingar av `Owner` på subscriptionen —
  om dei kan vere permanente, om MFA krevst — er tenantstyrte og usynlege i planen.
  Learn tilrår «Active admin: None» for Owner; det er den knappen som ikkje er
  kobla opp.
- **H5** `scripts/grant-graph-permissions.sh` manglar **`User.Read.All`**. Fire
  stader gjer `data "azuread_user"`. Provider-dokumentasjonen krev
  `User.Read.All` eller `Directory.Read.All`; `Group.ReadWrite.All` gir ikkje
  leserett på brukarar. Alle scope i tfvars brukar `owner` eller `dual`, så
  oppslaget skjer alltid. Skriptet avsluttar med «Verifiser at alle står som
  Granted» — og alt vil stå som granted, mens applyet likevel feiler.
- **H6** Repo 2 kan ikkje pakke M4-gruppene med mindre ho eig dei. Learn: for å
  legge ei role-assignable gruppe i ein access package må du vere User
  Administrator **og eigar av gruppa**. Eigaren er identiteten som køyrde *dette*
  repoet.
- **H7** «`entra_role` har ingen godkjenning i det heile» er feil. Tenantpolicyen
  gjeld, og for Entra-roller blir **aktive PRA/GA standardgodkjennarar** dersom
  ingen er valde — motsett av M2/M3. Same kjelde har ei åtvaring om at tenanten kan
  låsast ute. «Ingen godkjenning» kan lesast som «denne rolla er open», som er ei
  farlegare feilslutning enn den `activation_governance_gap` skal lukke.
- **H8** `azuread_directory_role` **kan ikkje deaktiverast**. Provideren gjer
  ingenting ved destroy. Eit `terraform destroy` etterlèt rollene aktiverte i
  tenanten. Ikkje dokumentert.

### Medium

- **Godkjenningsmekanikken:** 24-timarsvindauge, ikkje konfigurerbart. Første
  godkjennar avgjer. Service principals kan ikkje godkjenne. **Ingen kan godkjenne
  sin eigen forespørsel.** Ingenting av dette står i repoet.
- **SCIM-deprovisjonering er ikkje umiddelbar.** Aktivering provisjonerast i 2–10
  min, strupa til fem per 10 sekund; den sjette ventar til neste syklus, som går
  kvart 40. minutt. Og: *«Deactivation is done during the regular incremental
  cycle. It isn't processed immediately.»* Eit 8-timars medlemskap i
  `aws-jaws-admin` gir i verste fall opptil 40 minutt ekstra AWS-tilgang etter at
  Entra har trekt medlemskapet. Det er heile JIT-vindauget sin truverdigheit.
- **Kvotar og bivirkningar ved role-assignable grupper:** maks 500 per tenant;
  ingen nesting; **alle medlemmar og eigarar blir beskytta brukarar**, så ein
  Helpdesk Administrator kan ikkje lenger resette passordet deira. Den siste
  overraskar folk.
- **`eligible_assignment_rules.expiration_required = false` løysnar policyen for
  ALLE principals**, og det er default-oppførselen fordi `eligible_duration_days`
  er utelate overalt i tfvars. Å løysne ein tenantregel ved å *utelate* eit felt er
  uheldig standardretning.
- **Revisjonsspor:** 30 dagars retensjon, ingen diagnostic settings, ingen access
  reviews. Policyendringar framstår som deploy-identiteten, ikkje som eit menneske.
- **`max_activation_hours` 1–23** er strengare enn plattforma (1–24), og `PT30M` er
  utilgjengeleg fordi composite byggjer `"PT${hours}H"`. Unødig innsnevring for
  høgprivilegerte roller der 30 minutt er rett vindauge.

---

## Dokumentasjon — resten

### Daude referansar: 22 i to klassar

**Ti navngir ei arkivert fil** og kan finnast med grep. Verst:

- `README.md:9-10` — sender lesaren til `MALARKITEKTUR.md` og `OPPGAVE.md`, og seier
  at avvika er «dokumentert og begrunnet». Grunngjevinga er arkivert.
- `README.md:189` — første setning under «Kom i gang» peikar på `FORUTSETNINGER.md`.
- `README.md:241-245` — heile «Videre lesning» er fire daude lenker.

**Tolv brukar `R1`, `R3`, `B3` som etablerte identifikatorar.** Dei var det, i den
arkiverte fila. No er dei udefinerte **nokon stad**, og grep etter filnamnet finn
dei ikkje: `main.tf:252`, `variables.tf:188`, `terraform.tfvars:82`, `:312`,
`modules/azure-subscription-access/{variables.tf:84,main.tf:101}`,
`modules/pim-group-access/{variables.tf:119,main.tf:95,README.md:20}`,
`modules/entra-role-access/main.tf:129`, `modules/pim-for-groups/README.md:19`.

Billegaste fiks: ein kort «Risikoer og beslutninger»-seksjon i `README.md` med dei
tre-fire ID-ane som faktisk er i bruk, éi setning kvar. Då blir alle tolv gyldige
igjen utan at nokon av dei må endrast.

### Direkte feil

1. **`modules/entra-groups/README.md:67-70`** hevdar at modulen brukar separate
   `azuread_group_member`- og `azuread_group_owner`-ressursar med `ignore_changes`
   på begge. `owners` settast direkte (`main.tf:50-53`), `azuread_group_owner`
   finst ikkje i provideren, og `ignore_changes` har berre `members`. Tre feil i éi
   setning — og rot-README sitt sikkerheitsargument byggjer på denne mekanismen.
2. **`providers.tf:8-11`** — kommentaren seier «subscription_id er ikke satt her med
   hensikt … Sett ARM_SUBSCRIPTION_ID i miljøet», og linja under set
   `subscription_id = var.provider_subscription_id` frå ein påkravd variabel. Ein
   lesar som følgjer kommentaren får feilmelding om manglande variabel.
3. **`versions.tf:3-5`** — feil grunngjeving for at `time` ikkje er deklarert.
4. **`terraform.tfvars:258` / `.example:249`** — «Team-godkjenning. Gruppa må finnes
   fra før.» Scopet set ikkje `approver_group_name`, så repoet **opprettar** gruppa.
   Rest frå då feltet låg på rollenivå.
5. **`terraform.tfvars:223`** — «Gir grupper `aws-prod-konto-{rolle}`», men
   scope-keyen er `"jaws"`. Kommentar kopiert frå `.example`, verdiar bytta.
6. **`modules/pim-group-access/README.md:138`** — kall-eksempelet brukar
   `group_object_ids["aws-prod"]` med `scope_key = "prod-konto"`. Kopierbar kode med
   feil nøkkel.
7. **`README.md:205`** — «begge mekanismene». Det er tre.
8. **`modules/pim-for-groups/README.md:30`** — «Azure RBAC i denne POC-en» motseier
   modulens eige forord ni linjer over.
9. **`terraform.tfvars:10`** — «Verdiene her er FIKTIVE (Contoso)». Reell tenant-ID,
   subscription-ID, AWS-konto og gjeste-UPN-ar. Contoso finst berre i det
   utkommenterte GCP-blokket.
10. **`README.md:194`** listar det du skal fylle inn og **utelèt
    `provider_subscription_id`**, som er påkravd. Ein brukar som følgjer lista får
    feil ved plan.

### Kallbart frå dokumentasjonen? Nei

- **Ingen feltreferanse ein kan lenke til.** Full dokumentasjon av `access_scopes`
  finst på to stader, og dei er identiske: `terraform.tfvars.example:336-519` og
  `terraform.tfvars:345-528`. Referansen finst berre i fila brukaren blir bedt om å
  **kopiere**.
- **291 av 519 linjer i `.example` er prosa.** Alt arvast inn i brukarens eiga
  `terraform.tfvars` ved `cp` — 291 linjer dokumentasjon som ingen vedlikeheld, i
  ei fil som ikkje er i git.
- **Minimumssettet står ingen stad.** Ein 15-linjers tfvars med eitt scope og éi
  rolle, plassert i README, ville gjort meir for kallbarheita enn dei 519 linjene.
- **`outputs.tf` har 21 outputs, README nemner 13.** Dei to som svir mest:
  `approvers_by_role` (einaste maskinlesbare oversikt over kven som godkjenner kva)
  og `approver_group_is_managed_here` (governance-signal).
- **`scripts/grant-graph-permissions.sh` er ikkje nemnt i README** ein einaste gong,
  sjølv om README sjølv kallar manglande tilgangar «den vanligste blokkeren».

### Språk

- `variables.tf:394` — «trur» skal vere «tror». Einaste nynorske form i aktivt repo.
- `modules/azure-subscription-access/variables.tf:148` — «et slikt omgåelse» → «en
  slik omgåelse».
- `gruppa`/`gruppen` 99/19, `rolla`/`rollen` 100/6. Begge former er gyldig bokmål,
  men vekslinga les som slurv i eit dokument som elles er nøyaktig.

---

## Tilrådd rekkefølge

1. **F1 + F2 saman** — sentinelen og `expiration_required`. Rettar du berre F1,
   reparerer du halve. Einaste funnet der repoet aktivt lovar feil sikkerheit.
2. **F3** — `required_version >= 1.9`. Trivielt, og repoet kan i dag ikkje kjørast
   der det hevdar.
3. **N1** — vurder om `Groups Administrator` skal vendast i det heile, eller om
   M4-scopet må ha eit eige, strammare oppsett. Dette er ei designavgjerd, ikkje ein
   patch.
4. **B1–B4 som éin commit** — `providers.tf`, dei to variablane og `versions.tf`
   heng saman. Kan ikkje gjerast billig seinare.
5. **N3 + H4** — døyp om `activation_settings`, eller les frå ressursen.
6. **README-seksjon med R1/R3/B3** — lukkar tolv daude referansar med éin endring.
7. **Krymp `.example`**, flytt feltreferansen til README.
8. **R7, R12, R6** — tre valideringar på under tjue linjer til saman.
