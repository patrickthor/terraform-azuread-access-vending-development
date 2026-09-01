# Fagleg gjennomgang — tre uavhengige vurderingar

Tre agentar har gått gjennom repoet uavhengig av kvarandre: Terraform/IaC,
dokumentasjon og Entra ID. Agentdefinisjonane ligg i `.kiro/agents/` og kan kallast
på nytt.

Funn som fleire agentar fann uavhengig er merkte. Påstandane i «Verifisert»-lista
er etterprøvde, ikkje resonnerte.

---

## Verifisert før rapportering

| Påstand | Metode | Resultat |
| --- | --- | --- |
| `expire_after = null` gir `optional(string, "P30D")`-defaulten | isolert testprosjekt | **stadfesta** — `"permanent"`-sentinelen er daud kode |
| `expiration_required` i `active_assignment_rules` er Optional+Computed | `terraform providers schema -json` | **stadfesta** — og modulen set han aldri |
| Deploy-SP-en er eigar på alle grupper | `terraform state show` × 13 | **stadfesta** — `811bcf32-…` på alle 13, inkludert begge godkjennargruppene |
| Kryssvariabel-referanse i `validation` krev TF ≥ 1.9 | `variables.tf:284`, `:415`, to composites `:99`/`:134` | **stadfesta** — `required_version = ">= 1.5"` er feil i alle sju `versions.tf` |
| Repoet er applyet | `terraform.tfstate` serial 252, 27 ressursar | **stadfesta** |

---

## Dei fem funna som betyr mest

### 1. `"permanent"`-sentinelen har aldri verka — REELL FEIL

`main.tf:128-137` oversett `"permanent"` til `null`. Mottakaren er
`modules/pim-group-access/variables.tf:106`, `optional(string, "P30D")`. Terraform
erstattar eksplisitt `null` med optional-defaulten, så verdien blir `"P30D"`.
Skulle han sleppe gjennom, ville `modules/pim-for-groups/variables.tf` sin eigen
default tatt han i neste lag.

Retninga er mot strengare, ikkje svakare — men `variables.tf:337-350` og
feltreferansen i `terraform.tfvars` beskriv ein sikkerheitsrelevant knapp som ikkje
finst, og ingen plan viser det.

**Rotårsak, som er viktigare enn feilen:** defaultverdiane er triplisert (rot,
composite, leaf). Mønsteret nullable + `coalesce` i rota er rett løysing på
problemet — det er den einaste måten å skilje «ikkje satt» frå «satt til
defaulten», som `entra_role`-avvisingane er avhengige av. Men det er berre trygt
når laget under er ikkje-nullable og **utan** default, slik at ein manglande
`coalesce` feiler høgt i staden for å bli stille fylt inn. Neste sentinel døyr same
daude.

### 2. P30D-taket på aktive medlemskap er ikkje eit tak — REELL FEIL, sikkerheitsrelevant

`modules/pim-for-groups/main.tf:72-75` set `expire_after` men aldri
`expiration_required`. Attributtet er Optional+Computed, så tenantverdien blir
behalden. State viser `expiration_required = false` med `expire_after = "P30D"` ved
sida av — og i PIM-semantikk er `expiration_required = false` nettopp «tillat
permanente aktive tildelingar». `expire_after` er då berre taket for tildelingar
som *vel* å ha utløp.

Kontrasten er lærerik: på azurerm-sida viser state `expiration_required = true,
expire_after = P180D` — verdiar Terraform aldri har sett, arva frå tenanten. Same
mønster, motsett utfall, begge utanfor kontroll.

M3-stien har altså ikkje den JIT-garantien dokumentasjonen byggjer heile
sentinel-argumentasjonen på. **Funne uavhengig av både IaC- og Entra-agenten.**

Fiks: `expiration_required = var.active_assignment_expire_after != null`.

### 3. Deploy-SP-en er ståande eigar på alle 13 grupper — REELL FEIL mot intensjon

`main.tf:47-53` seier «Ingen faste medlemmer, ingen eiere».
`modules/entra-groups/main.tf:47-55` sender `null` når lista er tom, som per
kommentaren skal la Entra «beholde det standardoppsettet det lager selv».
Standardoppsettet er at skaparen blir eigar.

Repoets eige argument for `set_systemeier_as_group_owner = false` er at ein
gruppeeigar kan forvalte medlemskap direkte og omgå vendinga usett. Det argumentet
gjeld då for SP-en — **òg på godkjennargruppene, der medlemskap _er_
godkjenningsrett**. Og fordi attributtet er Optional+Computed med `null` i config,
vil Terraform korkje fjerne eigaren eller vise drift om nokon legg til fleire.

Entra-agenten går lenger og kallar det **høg** alvorsgrad: SP-en har samtidig
`Group.ReadWrite.All`, `RoleManagement.ReadWrite.Directory` og User Access
Administrator på subscriptionen. Med UAA kan han skrive ei permanent `Owner`-binding
til kven som helst, og med `Group.ReadWrite.All` legge ein brukar rett inn i
`azure-tommer-master` (eligible `Owner`). Eligible tildelingar kan ikkje opprettast
for service principals, så SP-en kan ikkje PIM-beskyttast.

Vurderinga «SP-en er eigar med vilje» er forsvarleg *så lenge* credentialsa
handterast som tenant-admin. Det er ikkje det same som least privilege, og repoet
framstiller det som eit nøytralt val.

### 4. Godkjennargruppene er tomme, og PIM har ingen fallback — POC-blokkerande

`main.tf:42-57` opprettar gruppa tom, med god grunngjeving («Godkjennere skal
aldri kunne omgå vendingen selv»). Men:

**[DOKUMENTERT]** Det finst ingen standardgodkjennarar for Azure-ressursroller
eller for PIM for Groups — til forskjell frå Entra-roller, der aktive Privileged
Role Administrator / Global Administrator blir standardgodkjennarar. Godkjennings-
vindauget er 24 timar og ikkje konfigurerbart.

Konsekvens: **alle `team`-roller er i praksis blokkerte no.** Forespørselen kan
sendast, ingen kan godkjenne, ho fell for tidsavbrot. I din tfvars gjeld det
`tommer--contriband` og `jaws--billing`. `dual` overlever fordi systemeier står i
same steget.

I tillegg er bootstrappinga udefinert: medlemskap i godkjennargruppa skal vendast
via access package i repo 2 — men **[DOKUMENTERT]** ein godkjennar kan ikkje
godkjenne sin eigen access package-forespørsel. Utan eit definert startpunkt er
det ei lukka løkke. Bør inn som eige punkt i kontrakten mot repo 2.

### 5. Dokumentasjonen hevdar at ingenting er applyet

`MALARKITEKTUR.md:21-23` — «**Ingenting er noen gang `apply`-et.**» — i det
dokumentet README ber deg lese *først*. State har 27 ressursar.

Det farlege er ikkje datoen, men at tre irreversible steg er formulerte som «må
testast før første apply» og alle er gjennomførte:

- Tre `aws-jaws-*`-grupper er PIM-onboarda. **[DOKUMENTERT]** ei gruppe kan ikkje
  tas ut av PIM-forvaltning igjen. R5 er ikkje ein risiko, det er ein tilstand.
- To role-assignable grupper er oppretta. `assignable_to_role` er immutabelt.
  R3-valet er teke.
- `Directory Readers` er **permanent** bunden på `/`, og `Groups Administrator`
  ligg **eligible** på `/` — utan at nokon aktiveringsregel er sett.

**Positivt sidefunn:** R1 kan lukkast. State viser
`azuread_group_role_management_policy` på tre grupper der
`assignable_to_role = false`. Policyen festar seg på vanlege sikkerheitsgrupper,
og **[DOKUMENTERT]** PIM onboardar gruppa implisitt når policyen skrivast.
`assignable_to_role` er altså **ikkje** nødvendig for M3.

---

## Terraform / IaC

### Bra

- **Dispatch på rolle med eksplisitt projeksjon** (`main.tf:84-176`). Meir kode enn
  `roles = scope.roles`, men det gjer det umogleg å smugle eit felt til ein
  mekanisme som ikkje les det — og det er grunnen til at feltvalideringane er
  etterprøvbare.
- **Provider-isolasjonen er reell på modulnivå.** `azure-rbac-on-group` er einaste
  modul med `azurerm`. Modulane har eigne lockfiler, så dei *er* init-a åleine.
- **Kollisjonsvalideringa på `(scope_id|azure_role)`** (`variables.tf:565-589`) er
  den beste enkeltvalideringa i repoet, og den einaste som *må* bu i rota. Din
  tfvars har faktisk to scope på same subscription, så det er ikkje ein tenkt
  situasjon.
- **Å avvise felt i staden for å ignorere dei** — sju stader.
- **`uuidv5`-namn** (`modules/azure-rbac-on-group/main.tf:60-67`) fjernar
  server-genererte GUID-ar frå state utan å koste noko, sidan alle tre
  inngangsverdiane alt er ForceNew.
- **Godkjennargruppa opprettast i rota** (`main.tf:180-195`) — grunngjevinga er
  korrekt og ikkje openbar.
- **`precondition` med `lookup(..., null)`** i M4 gir betre feilmelding enn
  provideren.
- **`.gitignore`** er gjennomtenkt, ikkje kopiert.

### Risiko

- **`required_version = ">= 1.5"` er feil; koden krev ≥ 1.9.** Kryssvariabel-
  referansar i `validation` på fire stader. På 1.5–1.8 feiler konfigurasjonen ved
  init med ei melding om ugyldig referanse, ikkje om versjon. Lokalt kjører 1.14.5,
  så det er usynleg — og difor står det feil.
- **`assignable_to_role` blir stille ignorert for `entra_role`** (`variables.tf:189`).
  Repoet avviser sju andre felt med presis denne grunngjevinga. Her er unntaket, og
  det er for det einaste force-replace-feltet.
- **Ingen propagerings-venting i M2.** M3 og M4 får `propagation_delay`, M2 ikkje.
  `azurerm_pim_eligible_role_assignment` har ingen `principal_type`-knapp og bind
  seg mot ei gruppe som kan vere sekund gammal.
- **`pim_group_propagation_delay` styrer to spor, dokumentert som eitt.** Å setje
  han til `"0s"` slår samtidig av ventinga før directory-rollebindingar.
- **Nøklane *er* identiteten, og det står ingen stad.** Å døype om ein rolle- eller
  scope-key riv gruppa og bryt oppslaget i repo 2 — to gonger for same handling.
  Same konsekvens som R3, som er dokumentert på fem stader; dette, som er langt
  lettare å gjere ved eit uhell, er ikkje nemnt. Ingen `moved`-rettleiing, ingen
  `prevent_destroy`.
- **`azuread_directory_role_eligibility_schedule_request` er ForceNew på alt** —
  inkludert `justification`. Ei kosmetisk redigering av standardteksten gir
  revoke/re-grant på ei directory-rolle.
- **Auto-importerte policyar kan ikkje leverast tilbake.** `destroy` fjernar
  objektet frå state og let tenanten stå med Terraform sine verdiar — for azurerm
  gjeld dei alle principals på (scope, rolle), også etter at gruppa er sletta.
- **`access_package_access_type` har to sanningskjelder** (rot reknar det ut,
  modulane reknar det ut sjølve). Dette er halvparten av kontrakten mot repo 2, og
  `outputs.tf:22-27` argumenterer sjølv for at slike reglar skal bu på éin stad.
- **Godkjennargruppe blir laga for scope som aldri brukar henne.** Filteret
  (`main.tf:32-40`) tar ikkje omsyn til `permanent_access`, men dei to stadene som
  avgjer om ho blir *brukt* gjer det.
- **Blanda scope kan gi eit gruppenamn som lyg.** `azure_pim` + `pim_for_groups` i
  same scope tvingar `cloud = "azure"`, og då får AWS-rolla namnet
  `azure-{scope}-{rolle}`. Det er presis den fella `variables.tf:280-290` er skrive
  for å stengje — regelen er handheva på tvers av scope, men ikkje inne i eitt.
- **Feilmeldinga i kollisjonsvalideringa gir dårleg råd:** «Sett
  `permanent_access = true` på én av dem» foreslår å byte JIT for permanent for å
  omgå ei teknisk avgrensing. Einaste staden i repoet der ei feilmelding peikar mot
  svakare tilgangskontroll.

### Stil

- `modules/entra-role-access/main.tf:79-82` — `local.unresolved_role_names` er daud
  kode.
- `versions.tf:1-5` — kommentaren om at `time` ikkje er deklarert fordi
  `pim-for-groups` «ikke kalles fra denne rot-modulen» er feil. Han blir kalla via
  `pim_group_access`, og `entra-role-access` brukar `time_sleep` direkte.
- **`description_template` er duplisert tre gonger** — same femdobbelt nøsta
  `replace()`-kjede, over eit plassholdarsett dokumentert som felles. Mest openbare
  kandidat for å flytte ned i `entra-groups`, og mest sannsynlege staden divergens
  skjer.
- **`"dual"` heiter noko det ikkje er.** At det trengst fem avsnitt for å forklare
  at éin signatur er nok, er signalet. `any_of` ville gjort fire av dei unødvendige.
- `terraform.tfvars:11` seier «Verdiene her er FIKTIVE (Contoso)». Fila har reell
  tenant-ID, subscription-ID og reelle gjeste-UPN-ar.

---

## Dokumentasjon

### Bra

- **`README.md:33-90`** er det beste enkeltartefaktet i repoet. Mekanismetabellen
  svarer på «kva lagar kvar mekanisme» på éin skjerm, og namngjev dei to
  governance-hola i staden for å gøyme dei.
- **Grunngjeving før regel er husstilen, og han fungerer.** Grunngjevinga ligg i
  sjølve feilmeldinga, så lesaren får ho i det sekundet ho betyr noko.
- **`outputs.tf` gjer hola observerbare i staden for berre dokumenterte.** Denne
  dokumentasjonen kan ikkje bli utdatert, fordi han blir rekna ut av same
  konfigurasjon han beskriv.
- **Modul-README-ane held kontrakten.** Output-tabellane i alle seks stemmer, namn
  for namn, mot `modules/*/outputs.tf`.
- **`modules/pim-group-access/README.md:186-196`** dokumenterer eit *fråvær* med
  grunn. Sjeldan og verdifullt.

### Direkte feil

Utover applyet-statusen (funn 5 over):

- **`PROSJEKT-SAMMENDRAG.md:196-203` (B7)** beskriv `approver_group_name` per rolle
  som påkravd, og at gruppa må finnast frå før. Alle tre påstandane er no feil. Ein
  lesar som følgjer B7 skriv ein tfvars som ikkje validerer.
- **`terraform.tfvars:258`** og `.example:249` — «Team-godkjenning. Gruppa må finnes
  fra før.» Verste plasseringa, fordi kommentaren står rett over feltet.
- **`MALARKITEKTUR.md:247` og `:365`** har framleis `systemeier = "ola@kunde.no"`
  som streng. Begge kodeeksempla i måldesign-dokumentet feilar på typekonvertering.
- **`modules/entra-groups/README.md:67-72`** hevdar at modulen brukar separate
  `azuread_group_member`- og `azuread_group_owner`-ressursar med `ignore_changes` på
  begge. `owners` er sett direkte på ressursen, `ignore_changes` har berre
  `members`, og `azuread_group_owner` finst ikkje i provideren — noko
  `PROSJEKT-SAMMENDRAG.md:264-268` sjølv slår fast.
- **`PROSJEKT-SAMMENDRAG.md:53-63`** beskriv PIM-modellen som PIM for Groups punkt
  for punkt — det motsette av M2 og av koden.
- **`PROSJEKT-SAMMENDRAG.md:431`** («ingen `terraform validate` er kjørt») motseier
  same fil sin `:365-367` («`validate` → Success») 65 linjer unna.
- **`MALARKITEKTUR.md:502`, `:520`** brukar feltnamnet `jit`, som aldri har
  eksistert. Same dokument brukar rett namn (`permanent_access`) i M2b.
- **`outputs.tf:105-116`** — `access_model`-beskrivinga listar tre verdiar og nemner
  ikkje `entra_role`, men `:127-131` merger inn M4.
- **`README.md:204`** — «eksempler på **begge** mekanismene». Det er tre.
- **`FORUTSETNINGER.md:9-12`** presenterer `az login` som hovudscenario. To av tre
  mekanismar kan ikkje køyrast slik, og fila nemner det ikkje. Same fil manglar
  begge M4-permissions, sjølv om ho er utpeikt som pre-apply-sjekkliste.

### Duplisering

- **`terraform.tfvars` mot `.example`: kring 380 identiske kommentarlinjer.**
  Divergensen har alt starta — `.example:403-404` namngjev `azure-tommer-approvers`
  og `aws-jaws-approvers`, scope-nøklar frå den *andre* fila. Kjelde bør vere
  `.example`, som ligg i git.
- **Mekanisme-tabellen finst i fire uavhengige versjonar**, og dei er alt ulike.
  `modules/pim-group-access/README.md` har rada «Risiko R1 gjelder» — den mest
  utdaterte rada i repoet.
- **«Dual degraderer til eitt steg» står på elleve stader.** Referansen har alt
  divergert: éin peikar til «beslutning 2», dei ti andre til B3.

### Manglande grunngjeving

- **`MALARKITEKTUR.md` nemner ikkje godkjennargruppa. Ikkje éin gong.** Null treff
  på «approver» eller «godkjennergruppe». Dette er dokumentet README seier «les
  først», og som eig grunngjevingane. Ein lesar som følgjer tilrådd leserekkefølge
  får B7 som einaste svar på kven som godkjenner, og B7 er feil.
- **Ingen stad står det at ein `team`-rolle ikkje kan aktiverast i dag.** Funn 4 er
  eit POC-blokkerande faktum utan anker.
- **Avveginga i «éi gruppe per scope» er ikkje skriven ned.** At same gruppe
  godkjenner både `Contributor` og `Owner` står ingen stad, verken som konsekvens
  eller som medvite val.

### Navigerbarheit

Ein ny utviklar kan **ikkje** finne ut kva som skal i tfvars utan å lese
kommentarane. Det finst inga feltreferanse for `access_scopes` i nokon README.

`.example` på 519 linjer er eit dårleg val av to grunnar. Referansen ligg *bak* 226
linjer eksempel ein nykomar ikkje kan tolke enno. Og `.example` er fila du
*kopierer* — `terraform.tfvars` er beviset, med 380 dupliserte linjer som alt har
divergert.

Konkret: flytt `.example:331-519` inn i `README.md` etter mekanismetabellen, og
kutt `.example` til header pluss eitt scope per mekanisme.

### Språk

Bokmål er standarden, med tre unntak: **`MALARKITEKTUR.md:317-328`** er heilt
nynorsk (inkludert overskrifta «Krav og forutsetningar»), **`:537`** har «gatar»,
og **`FORUTSETNINGER.md:57`/`:60`** har «Kva er eg» og «Har eg» i bash-kommentarar.
`variables.tf:394` har «trur» for «tror».

`modules/azure-subscription-access/variables.tf:148` — «et slikt omgåelse» →
«en slik omgåelse». Same setning er rett to andre stader.

**«eier» har tre tydingar innanfor éi skjermhøgd i README:** gruppe-eigar i
Graph-tydinga, `systemeier` som ansvarleg person, og `owner` som verdi av
`approval_type`. Kollisjonspunktet er `README.md:137`.

**Same verdi har to namn:** rota kallar det `scope_key`, M2-modulen
`subscription_key`.

---

## Entra ID

### Bra

- **Dei tre PIM-modellane er kvar for seg rett forstått.**
  `azuread_group_role_management_policy` mot `group_id` er rett brukt, og
  `depends_on`-rekkefølgja er rett av rett grunn.
- **M2-valet unngår ei reell felle repoet ikkje eingong nemner.** Fordi M2-gruppene
  ikkje er PIM-forvalta og medlemskapet er aktivt, held det med **éi** aktivering.
  **[DOKUMENTERT]** er du eligible for ei gruppe som sjølv har ei eligible
  rollebinding, må du aktivere to gonger. Mønsteret repoet valde er òg det
  Microsoft tilrår.
- **Eitt-stegs-degraderinga er korrekt forstått.** **[DOKUMENTERT]** godkjenning i
  PIM blir avgjort av den første som svarar.
- **`assignable_to_role` er handtert rett.** **[DOKUMENTERT]** immutabelt, ingen
  nesting, tak på 500 per tenant.
- **Ei gruppe kan ikkje eige ei gruppe** — **[DOKUMENTERT]**. Godkjennar-i-staden-
  for-eigar er difor ikkje eit val mellom to modellar, det er den einaste som
  finst. Det bør stå i dokumentasjonen; i dag les det som ein preferanse.
- **Aktiveringspolicy før eligibility**, med `eligible_assignment_rules` og
  dokumentert rekkevidde («gjeld alle principals på (scope, rolle)»).
- **Escape hatches er synlege i output** — `demo_eligibility_schedules`,
  `approver_group_is_managed_here`.

### Kritisk / høg

- **Lisenspremisset er sjølvmotstridande.** `OPPGAVE.md:6` seier «Ingen
  Governance-tillegg»; `FORUTSETNINGER.md:114` og `MALARKITEKTUR.md:322` seier
  «bekreftet på plass». **[DOKUMENTERT]** eligible gruppemedlemskap i access
  packages krev Entra ID Governance eller Suite; vanleg «Member»-gruppetildeling er
  dekt av P2. Altså: **M2 og M4 kan testast på rein P2. M3 kan ikkje.** På rein P2
  vil `EligibleMember` ikkje vere valbart i det heile, og feilen kjem i repo 2 der
  ho vil sjå ut som ein bug i repo 2. Må avklarast mot faktisk SKU.
- **M4-hòlet er ikkje handtert — det er berre synleggjort.** Ingen `precondition`,
  ingen check-block, ingen dokumentert verifikasjonssteg stoppar apply til reglane
  er sette i portalen. Ei gruppe er no eligible for Groups Administrator under kva
  enn tenanten har som default. To poeng repoet ikkje nemner: **[DOKUMENTERT]** for
  Entra-roller blir aktive PRA/GA standardgodkjennarar om ingen er valde — motsett
  av M2/M3; og Groups Administrator kan forvalte medlemskap i ikkje-role-assignable
  grupper, altså i M2-gruppene, inkludert den som er eligible for `Owner`. Burde
  vore bak eit eksplisitt flagg, ikkje ein kommentar.
- **Kryssrepo-blokkering for M4.** **[DOKUMENTERT]** for å leggje ei
  role-assignable gruppe i ein access package må den som gjer det vere User
  Administrator **og eigar av gruppa**. Repo 2 sin identitet er ikkje eigar —
  deploy-SP-en her er. M4-gruppene kan difor ikkje pakkast av repo 2 slik oppsettet
  står.

### Graph-permissions

`scripts/grant-graph-permissions.sh:25-38` har tre separate problem:

- **Manglar ein permission koden trur den har.** Modulane gjer `data "azuread_user"`
  og set `owners` til brukarobjekt. **[DOKUMENTERT]** for at ein app skal opprette
  ei gruppe med brukarar som eigarar må han ha minst `User.Read.All`. Ikkje i lista.
  Første SP-baserte apply på ein konfigurasjon med
  `set_systemeier_as_group_owner = true` vil feile med 403 på systemeigar-oppslaget,
  og feilmeldinga vil ikkje peike på gruppa.
- **For breitt der det kunne vore smalare.** Least-privileged for oppretting er
  `Group.Create`, ikkje `Group.ReadWrite.All`. Repoet set aldri medlemskap.
- **Kommentaren og koden er ueinige.** `:34-36` seier «ta dei bare hvis du faktisk
  bruker `entra_role`», men `:37-38` ligg ukondisjonelt i arrayet.
  `RoleManagement.ReadWrite.Directory` er den kraftigaste permissionen i tenanten og
  bør vere eit argument til scriptet, ikkje ein kommentar.

### Token- og claim-propagering

Dokumentert for berre éin av tre mekanismar:

- **M3:** aktivering gir aktivt medlemskap på sekund, men appen kan ha cacha det
  motsette. Dokumentert i repoet. Bra.
- **M2:** **[DOKUMENTERT]** PIM opprettar den aktive tildelinga på sekund, men
  rollebindingsendringar kan ta inntil 10 minutt pga. ARM-cache. **Ikkje
  dokumentert nokon stad.**
- **M4:** same cache-førbehald. **Ikkje dokumentert.**

Testpunkt 2 i `OPPGAVE.md:161` er nettopp å måle dette, og den som skal måle har
ikkje fått vite kva han skal forvente.

### Revisjonsspor

Ingen treff på «audit», «revisjon» eller «logg» i noko dokument. Med tre mekanismar
ligg sporet tre stader — PIM for Azure Resources, PIM for Groups, Entra
rollehistorikk — pluss access package-historikken i repo 2. **[DOKUMENTERT]**
PIM-historikken dekkjer 30 dagar. For eit design som skal demonstrere governance er
det ein reell mangel at det ikkje står ei linje om kvar ein leitar.

### Mindre

- `PROSJEKT-SAMMENDRAG.md:127` seier access package-policy støttar «opptil 2»
  godkjenningssteg. **[DOKUMENTERT]** opp til **tre**, med alternative godkjennarar
  og eskalering. Det styrkjer konklusjonen om at fleirstegs godkjenning høyrer i
  repo 2, men premisset er feil.
- `modules/pim-for-groups/variables.tf` — regexen for
  `maximum_activation_duration` godtek `PT0H`. Uråd å nå frå rota, men modulen er
  meint å vere sjølvstendig.
- `modules/pim-for-groups/main.tf:74` brukar same `require_justification` for både
  aktivering og aktive tildelingar. To ulike reglar, éin knapp.
- `MALARKITEKTUR.md` sitt opne punkt om at det er uklart om `principal_id` godtek ei
  gruppe: state viser at det fungerer. Kan lukkast.

---

## Tilrådd rekkefølge

1. **Rett `expiration_required` i M3** — einaste funnet som endrar faktisk
   sikkerheitspositur.
2. **Fyll godkjennargruppene, eller byt `team` til `dual`** — elles er dei rollene
   ikkje aktiverbare, og POC-en kan ikkje demonstrerast.
3. **Rett `required_version` til `>= 1.9`** — trivielt, og repoet kan i dag ikkje
   kjørast der det hevdar å kunne kjørast.
4. **Rett applyet-statusen** i `MALARKITEKTUR.md:21` og
   `PROSJEKT-SAMMENDRAG.md:385` — og lukk R1, som no er dokumentert løyst.
5. **Avklar lisens mot faktisk SKU** før meir M3-arbeid.
6. **Skriv godkjennargruppa inn i `MALARKITEKTUR.md`**, og rett B7 i
   `PROSJEKT-SAMMENDRAG.md`.
7. **Bestem kva `"permanent"`-sentinelen skal vere** — fjern han, eller gjer
   composite-variablane ikkje-nullable utan default slik at han faktisk verkar.
