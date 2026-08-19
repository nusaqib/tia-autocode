# tia-autocode — User Guide

A practical, task-oriented walkthrough. For the full feature list and cmdlet
reference see [SPECIFICATION.md](SPECIFICATION.md); for raw Openness idioms see
[openness-cheatsheet.md](openness-cheatsheet.md).

---

## 0. One-time setup

1. **Install / confirm TIA Portal** (V19 and/or V21) and that Openness is registered.
   Check with:
   ```powershell
   Import-Module .\src\TiaOpenness\TiaOpenness.psd1 -Force
   Get-TiaInstalledVersion
   ```
2. **Join the Openness group** (once, elevated), then **log off/on**:
   ```powershell
   # Run as administrator:
   .\scripts\Enable-OpennessAccess.ps1
   # then log off and back on (or reboot)
   ```
   Why the re-login: Windows only puts the new group into your token at logon. Until
   then `Get-TiaSession` works but `Connect-TiaPortal` throws a security error.
3. **Verify**:
   ```powershell
   .\scripts\Validate-Full.ps1     # exercises attach + a full scratch write path
   ```

> Must run under **Windows PowerShell 5.1** (Desktop). PowerShell 7 can't load Openness.

---

## 1. Connect

```powershell
Import-Module .\src\TiaOpenness\TiaOpenness.psd1 -Force

Get-TiaSession                 # what's running?
$c = Connect-TiaPortal         # attach to the running Portal (read-oriented)
$c.OpenProjects
```

Start your own instance instead (recommended for writes):

```powershell
Connect-TiaPortal -New -WithUserInterface:$false   # headless engineering
```

Pick a version explicitly when both are installed:

```powershell
Connect-TiaPortal -Version 21.0
```

---

## 2. Explore an existing project (read-only)

```powershell
Get-TiaPlc                                  # CPUs
$plc = (Get-TiaPlc | Select-Object -First 1).PlcSoftware

Get-TiaTagTable -Plc $plc
Get-TiaTag      -Plc $plc | Where-Object DataType -eq 'Bool' | Select-Object -First 20
Get-TiaBlock    -Plc $plc -Type FC
Get-TiaBlock    -Plc $plc | Group-Object Type
```

Detach without disturbing the session:

```powershell
Disconnect-TiaPortal
```

---

## 3. Build a project from scratch

```powershell
Connect-TiaPortal -New -WithUserInterface:$false
New-TiaProject -Name Line1 -Path C:\work\Line1
# Validated CPU on this machine (S7-1515F-2 PN); swap for your catalog's MLFB:
New-TiaDevice  -TypeIdentifier 'OrderNumber:6ES7 515-2FM02-0AB0/V2.9' -Name PLC_1
$plc = (Get-TiaPlc | Select-Object -First 1).PlcSoftware
```

(For the right order number see [adding-a-device.md](adding-a-device.md). Easiest is to
keep a project template that already contains your CPU and `Open-TiaProject` a copy.)

---

## 4. Create tags

```powershell
New-TiaTag -Plc $plc -TagTable IO -Name Start_PB  -DataType Bool -Address '%I0.0' -Comment 'start'
New-TiaTag -Plc $plc -TagTable IO -Name Stop_PB   -DataType Bool -Address '%I0.1'
New-TiaTag -Plc $plc -TagTable IO -Name Motor_Run -DataType Bool -Address '%Q0.0'
New-TiaTag -Plc $plc -TagTable IO -Name Level_Raw -DataType Int  -Address '%IW64'

Get-TiaTag -Plc $plc -TagTable IO
```

---

## 5. Author logic (SCL-first)

A reusable **function** (FC):

```powershell
Import-TiaScl -Plc $plc -Scl @'
FUNCTION "Scale" : Real
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT
    raw : Int; hi_eng : Real; lo_eng : Real;
END_VAR
BEGIN
    #Scale := #lo_eng + (INT_TO_REAL(#raw) / 27648.0) * (#hi_eng - #lo_eng);
END_FUNCTION
'@
```

A **function block** (FB) with state:

```powershell
Import-TiaScl -Plc $plc -Scl @'
FUNCTION_BLOCK "MotorStarter"
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT  Start : Bool; Stop : Bool; END_VAR
VAR_OUTPUT Running : Bool; END_VAR
BEGIN
    IF #Start THEN #Running := TRUE;  END_IF;
    IF #Stop  THEN #Running := FALSE; END_IF;
END_FUNCTION_BLOCK
'@
```

An **instance DB** and the **main OB** that calls it:

```powershell
New-TiaDataBlock -Plc $plc -Name Motor1_DB -OfType MotorStarter

New-TiaOb -Plc $plc -Scl @'
ORGANIZATION_BLOCK "Main"
BEGIN
    "Motor1_DB"(Start := "Start_PB", Stop := "Stop_PB");
    "Motor_Run" := "Motor1_DB".Running;
END_ORGANIZATION_BLOCK
'@
```

Import logic from files instead of inline text:

```powershell
Import-TiaScl -Plc $plc -Path .\templates\Scale.scl
```

---

## 6. User data types (UDTs)

```powershell
New-TiaType -Plc $plc -Scl @'
TYPE "MotorData"
STRUCT
    Speed : Real; Running : Bool; Faults : Word;
END_STRUCT;
END_TYPE
'@
```

Use it in a global DB:

```powershell
New-TiaDataBlock -Plc $plc -Scl @'
DATA_BLOCK "Motors"
{ S7_Optimized_Access := 'TRUE' }
VAR  M1 : "MotorData"; M2 : "MotorData"; END_VAR
BEGIN
END_DATA_BLOCK
'@
```

---

## 7. Compile & check

```powershell
$r = Invoke-TiaCompile -Plc $plc
"State=$($r.State) Errors=$($r.Errors) Warnings=$($r.Warnings)"
$r.Messages | Select-Object -First 20
Save-TiaProject
```

Always confirm `Errors -eq 0` before treating a build as done.

---

## 8. Organize, delete, export

```powershell
New-TiaBlockGroup -Plc $plc -Path 'Motion/Axes'
Get-TiaBlockGroup -Plc $plc

Remove-TiaBlock -Plc $plc -Name OldFc -WhatIf     # preview
Remove-TiaBlock -Plc $plc -Name OldFc             # confirm & delete

# Diffable XML snapshot for git:
Export-TiaProgram -Plc $plc -OutDir .\export\PLC_1 -IncludeTags
Export-TiaBlock   -Plc $plc -Name MotorStarter -Path .\MotorStarter.xml -Overwrite
```

---

## 9. HMI (WinCC)

Create a panel from a catalog order number (validated live with a KTP700 Comfort):

```powershell
New-TiaHmiDevice -OrderNumber '6AV2 124-1GC01-0AX0/17.0.0.0' -Name HMI_1 `
                 -DeviceItemName 'KTP700 Comfort'   # /version is the panel image
```

HMI collections vary by WinCC flavor — **inspect first**:

```powershell
Get-TiaHmi
Show-TiaHmiApi -Hmi HMI_1          # reveals ScreenFolder, TagFolder, Connections, ...
```

**Check `SoftwareType` before scripting screens.** A *Unified Comfort Panel*
(`6AV2 128-*`) reports `HmiUnified.HmiSoftware` and is a different object model from a
classic Comfort panel (`Hmi.HmiTarget`) despite the similar name. `Get-TiaScreen` reports
which one you have in its `Flavor` column.

On **Comfort/Advanced**, screens are authored via XML round-trip:

```powershell
Get-TiaScreen    -Hmi HMI_1
Export-TiaScreen -Hmi HMI_1 -Name Start -Path .\Start.xml   # template / backup
# edit Start.xml ...
Import-TiaScreen -Hmi HMI_1 -Path .\Start.xml -Overwrite
```

On **Unified** there is no screen XML at all (`HmiScreen` exposes only `Delete()`), but
the object model is richer — build the screen directly (validated live on V19):

```powershell
New-TiaScreen -Name Overview -Width 1920 -Height 1080
New-TiaScreenItem -Screen Overview -Name Gate_BTA -Type Button `
                  -Left 40 -Top 40 -Width 160 -Height 60
Set-TiaScreenItemTag -Screen Overview -Item Gate_BTA -Property ProcessValue -Tag BTA_Gate_OK
```

All three are idempotent, so re-running a generator converges. `Export-/Import-TiaScreen`
refuse on Unified with a message naming the flavor rather than failing on the missing
`ScreenFolder`. See section 11.7 for the two API traps this hides.

Tags and connections (discovery-first wrappers):

```powershell
Get-TiaHmiConnection -Hmi HMI_1
Get-TiaHmiTag        -Hmi HMI_1
New-TiaHmiTag -Hmi HMI_1 -Name MotorSpeed -DataType Real `
              -Connection HMI_Connection_1 -PlcTag '"Motor1_DB".Speed' -TagTable Motors
```

Tag tables and alarms also round-trip as XML (`Export-/Import-TiaHmiTagTable`,
`Export-/Import-TiaHmiAlarms -Kind Discrete|Analog`). In a spec, the `hmis` section
drives all of this: `orderNumber` (create the panel), `tags` (CSV), `tagTablesXml`,
`alarms`, `screens`.

> **On WinCC Comfort/Advanced you cannot create HMI tags via the API** (the tag
> collection has no `Create`; the DataType is a typed link). Author them via tag-table
> XML import (`Import-TiaHmiTagTable`); `New-TiaHmiTag` is for flavors that expose a tag
> `Create`. These wrappers are reflection-based — validate on a scratch panel first.

See the `tia-hmi` skill for details.

---

## 10. Declarative build (generate a whole program)

Describe the program as JSON (see [../specs/demo.json](../specs/demo.json)) and run:

```powershell
$result = Invoke-TiaBuildFromSpec -Path .\specs\demo.json
$result.Ok
$result.Steps
$result.Errors        # per-item failures collected here (build doesn't abort)
```

This is the fastest path from "nothing" to a compiled program: portal → project →
device → modules → UDTs → logic → DBs → tags → compile → HMI (tags/alarms/screens) →
save. Keep specs in git
as the source of truth; regenerate any time.

### 10.0 Start a new machine repo (Phase 5)

Scaffold a private, per-machine repo that consumes this engine as a submodule:

```powershell
New-TiaProjectRepo -Path C:\work\Line5 -Name Line5
cd C:\work\Line5
git init
git submodule add https://github.com/nusaqib/tia-autocode.git engine
git submodule update --init --recursive
powershell -ExecutionPolicy Bypass -File .\validate.ps1   # offline, no TIA
powershell -ExecutionPolicy Bypass -File .\build.ps1      # needs TIA Portal
```

You get a ready manifest, starter `data/*.csv` + `logic/*.scl`, `build.ps1`/`validate.ps1`,
a `.gitignore`, and an offline-validation GitHub Actions workflow. Edit the data/logic,
keep `validate.ps1` green in CI, and build when you are on a TIA machine.

### 10.1 Authoring helpers (Phase 4)

**Author in Excel, not just CSV.** Anywhere a spec references a `.csv`, you can point at
a workbook sheet instead - `data/PLC_1.xlsx#Tags`. Reading is dependency-free (no Excel):

```powershell
Import-TiaXlsx -Path .\data\PLC_1.xlsx -Sheet Tags   # rows, like Import-Csv
```

**Lint your naming.** Add a `naming:` section to the manifest (or pass `-Rules`), then:

```powershell
Test-TiaNaming -Path .\project.yaml    # { Ok, Violations, Summary }
# rules per kind: pattern (regex), prefix, suffix, maxLength, case (Pascal|camel|UPPER|lower|snake)
```
`Test-TiaSpec` runs this automatically when a `naming:` section is present and reports
any violations as warnings.

**Reuse logic via templates.** List and instantiate parameterized SCL/UDT templates:

```powershell
Get-TiaTemplate | Format-Table Name, Kind, Description
Expand-TiaTemplate -Name MotorStarter -Parameters @{ Name='FB_Conveyor' }
```
In a spec, a `logic` entry can be a template instead of a file:
`- { template: MotorStarter, params: { Name: FB_Conveyor } }`. Drop your own `.tmpl`
files in a folder and pass `templateDir` to use a project-specific library.

---

## 11. Download to a CPU (real/simulated hardware)

```powershell
Get-TiaOnlineState -Plc $plc
Invoke-TiaDownload -Plc $plc -WhatIf     # preview
Invoke-TiaDownload -Plc $plc             # confirm; requires an online connection
```

> `Invoke-TiaDownload` affects real hardware/PLCSIM. Compile first, and only target a
> CPU you intend to change. The pre/post delegates may need tailoring to your setup.

---

## 11.6 Simulating a SAFETY CPU (PLCSIM / PLCSIM Advanced)

An F-CPU simulates, but **PROFIsafe F-I/O does not**. No F-module ever establishes a
connection, so the F-system passivates every one of them and substitutes **0** into the
input process image. Under the usual fail-safe convention (`1 = OK`) that means every
channel reads *fault*, nothing ever goes permissive, and `ACK_REI` cannot help - there is
no module to reintegrate to.

Three things block a simulated test, and they stack:

| Blocker | What you see | Handling |
|---|---|---|
| Safety mode is active | modifying any F-data is refused | Safety Administration -> **Deactivate safety mode** (online, needs the safety password). It is a CPU runtime state, so it does not travel with the project. |
| F-I/O passivated | `%I` of an F-module is held at 0 and cannot be modified | unavoidable - drive the DB members instead of the inputs |
| the IOMap layer | a modified DB member reverts within one cycle | it copies tags -> members every scan; stop it running (below) |

The working recipe, in a **throwaway copy**:

1. Remove the IOMap block's call from the safety runtime FB (it calls
   IOMap -> Certified -> Safety; drop the first). The certified and interlock blocks stay
   untouched, so what you test is the real logic.
2. Download, deactivate safety mode.
3. Modify `<DB>.<Area>.<Device>.<Component>.ChA` / `.ChB` from a watch table and watch
   `Interlocks_OK`, `Area_Safe`, `System_Safe`.

> **That build must never leave the bench.** With no IOMap call, nothing writes ChA/ChB,
> so every device reads whatever is left in the DB - the "member nothing writes" hazard,
> which looks like working logic. Keep it in a disposable folder and do not commit it.

Simulation validates program logic only. F-signatures, PROFIsafe addressing, sensor
evaluation, discrepancy times and field wiring are not exercised by it and cannot be
signed off from it.

---

## 11.5 Sheet-driven safety builds (Phase 7)

For a safety system, a manifest is the wrong authoring surface: every safety-relevant fact
needs to be an explicit, reviewable cell with a drawing reference. The design-sheet
pipeline makes a workbook the single source of truth and reduces the generators to
mechanical translation.

```
design/<book>.xlsx  --Sync-TiaDesignSheet-->  design/csv/  (COMMITTED - the build input)
                    --Test-TiaDesignSheet-->  pass/fail    (offline: no TIA, no network)
                    --Invoke-TiaSheetPipeline-->  TIA
```

```powershell
Sync-TiaDesignSheet  -Path .\design                    # workbook -> csv snapshot
Sync-TiaDesignSheet  -Path .\design -DiffOnly          # preview, write nothing
Test-TiaDesignSheet  -Path .\design\csv                # the gate; non-zero exit for CI
Test-TiaDesignSheet  -Path .\design\csv -RequireVerified   # unverified rows become errors
Invoke-TiaSheetPipeline -Path .\design\csv -Clean -Save     # all eight phases
Invoke-TiaSheetPipeline -Path .\design\csv -From DB         # resume after a fix
Export-TiaDesignWorkbook -Path .\design\csv -Out .\design\book.xlsx -Force   # inverse of Sync
```

The eight phases are **Project, Hardware, UDTs, DB, Tags, IOMap, Certified, Interlocks**,
each with defined input tabs, a defined output and its own gate. The pipeline stops at the
first failure - the phases are a chain, so continuing would build safety logic on a
known-bad foundation.

Why the CSV snapshot is committed rather than fetched at build time: an `.xlsx` is a binary
blob, so `git diff` on it says nothing, and for a safety design the per-cell change record
*is* the review evidence. It also keeps the build reproducible from a checkout alone.

The schema contract - every tab, column, enum, and validation rule - is
[DESIGN-SHEET.md](DESIGN-SHEET.md).

---

## 11.7 WinCC Unified screens: what Openness does and does not give you

All verified live on V19 against a `6AV2 128-3QB06-0AXx` Unified Comfort Panel. Do not
re-spike these.

- **A Unified Comfort Panel is not a Comfort panel.** It reports
  `Siemens.Engineering.HmiUnified.HmiSoftware`, not `Siemens.Engineering.Hmi.HmiTarget`.
  The names are close enough to send you down the wrong path for an hour.
- **There is no `ScreenFolder` on Unified** - screens hang off `sw.Screens` directly, as a
  flat `HmiScreenComposition`. Code that reaches for `ScreenFolder` gets a null reference,
  not a helpful error.
- **Unified screens have no XML round-trip.** `HmiScreen` exposes exactly one relevant
  method - `Delete()`. There is no `Export()`/`Import()`. Screen XML is a
  Comfort/Advanced-only concept, so the usual "export a template, edit it, re-import" plan
  simply does not exist here.
- **In exchange, everything is directly creatable**: `Screens.Create(name)`,
  `ScreenItems.Create<T>(name)`, `Dynamizations.Create<T>(propertyName)`, and every
  property (position, size, colour, font, `IOFieldType`, `Visible`, ...) is a settable
  CLR property. Unified is the *easier* flavor to generate, not the harder one.
- **Those `Create` methods are generic**, and Windows PowerShell 5.1 has no syntax for
  calling a generic method. They must be invoked via `MakeGenericMethod` - the same
  constraint that applies to `GetService<T>`.
- **Signed/unsigned is inconsistent within one object.** A screen item's `Left`/`Top` are
  `Int32` while `Width`/`Height` are `UInt32`. Passing a PowerShell `[int]` to
  `PropertyInfo.SetValue` throws *"Object of type 'System.Int32' cannot be converted to
  type 'System.UInt32'"*. Always `[Convert]::ChangeType($v, $p.PropertyType)` first.
- **Widget types span three namespaces** under `Siemens.Engineering.HmiUnified.UI` -
  `.Widgets` (Button, IOField, Gauge, Bar, Slider, ToggleSwitch, ...), `.Shapes`
  (Rectangle, Circle, Line, Polygon, Text, GraphicView, ...) and `.Controls`
  (AlarmControl, TrendControl, FaceplateContainer, ...). Resolve by type name across all
  of them rather than assuming one namespace.
- **34 of 38 screen-item types are creatable.** Surveyed live by create-then-delete. The
  four that throw *"Not supported"* are `HmiLabel`, `HmiProcessControl`,
  `HmiCustomWidgetContainer`, `HmiCustomWebControlContainer`. Use `HmiText` for a static
  caption - `HmiLabel` looks like the obvious choice and cannot be created.
- **A raw tag binding assigns the value; to drive a colour you need the MappingTable.**
  `dyn.ValueConverter.MappingTable` with `ConditionType = Range` and one
  `MappingTableEntryRange` per value converts a BOOL into a `System.Drawing.Color` (or a
  `Visible` flag). `Entries.Create<T>()` is generic; `RangeType` is read-only and derived
  from `From`/`To`; `Value` wants a real `Color`, not a hex string; `Flashing` is per
  entry. `Set-TiaScreenItemTag -ValueMap @{0=$red;1=$green} -FlashOn 1` wraps all of it.
- **Static text is read-only HTML.** `HmiText.Text` is a `MultilingualText` whose property
  cannot be assigned; set `.Text.Items[0].Text`, and it must be
  `<body><p>...</p></body>` - a bare string is rejected. `Font` is likewise read-only
  while `Font.Size` / `Font.Weight` are writable. **This applies to `HmiButton.Text` too** -
  a button caption is rich text, and a bare string fails with *"The argument 'text'
  (CAPTION) has an invalid format."*
- **HMI tags: `New-TiaHmiTag` does not work on Unified.** It cannot resolve the tag
  collection and reports the flavor as `Object[]`, then suggests the Comfort/Advanced
  tag-table XML round trip - which is wrong advice here. Create tags natively:
  `HmiTagTable.Tags.Create(name)`, which accepts `(name)` or `(name, tagTableName)`.
- **Do NOT set `HmiTag.DataType`.** Assign `Connection`, then `PlcTag`, and TIA resolves
  the data type itself - by the time `PlcTag` is set, `DataType` already reads the PLC
  tag's own type. Assigning `DataType` explicitly throws *"Empty data type or HMI data
  type at tag ..."* both ways round: before `PlcTag` there is nothing to resolve against,
  and after it is already correct. On Unified these three are plain `String` properties,
  unlike Comfort/Advanced where `DataType` is a typed link.
- **A UDT-typed HMI tag makes the whole PLC structure reachable by path.** One tag of type
  `"ZoneData"` pointed at `DB_Plant.Zone1` lets any screen item bind to
  `Zone1_Tag.Motor3.Running`. Four tags instead of several hundred flat ones, and
  adding a member to the UDT needs no HMI tag work at all.
- **Screen navigation is a script on an event handler.**
  `button.EventHandlers.Create(HmiButtonEventType.Tapped)` returns a handler whose
  `Script` property is **read-only** - set the code on the object it returns:
  `handler.Script.ScriptCode = "HMIRuntime.UI.SysFct.ChangeScreen('Overview','~');"`.
  **It is `SysFct`, not `SysFn`**, the verb is `ChangeScreen`, and it takes a second
  argument - the screen-window path, where `"~"` is the current window. Every other
  spelling compiles to *"Invalid object member"*; the authoritative list of the 34 `SysFct`
  methods is in the runtime's own unit tests under
  `WinCCUnified/bin/_config/IOWA_*.xml`, which is faster than guessing. The
  event enum lives at `Siemens.Engineering.HmiUnified.UI.Enum.HmiButtonEventType` and each
  widget has its own (`HmiRectangleEventType`, `HmiTextEventType`, ...), all offering
  `Tapped`. This is the whole mechanism behind a screen hierarchy.
- **There is no start-screen property on V19's `HmiSoftware`.** Nothing under `Screens` /
  `ScreenGroups` sets which screen the runtime opens on, so a generated hierarchy is
  unreachable until someone points the start screen at it **in the GUI**. Budget for that
  manual step, or the operator lands on whatever was configured before.
- **`ScreenGroups` exists on V19 but reads 0** on a real project - see the note below about
  presence of a property not proving a working API.
- **Faceplate *types* cannot be created through Openness ON V19 - but they can on V21.**
  This is version-specific, so check the assembly you are actually bound to:

  | | V19 (`Siemens.Engineering.dll`) | V21 (`Siemens.Engineering.Base.dll`) |
  |---|---|---|
  | `LibraryTypeComposition` | `Find`/`Contains`/enumerate only | adds **`CreateFromDocuments(DirectoryInfo, String, LibraryImportOptions)`** |
  | `FaceplateLibraryTypeVersion` | `Export`, `Delete`, `FindInstances` | adds **`ExportAsDocuments(...)`**, `Edit()`, `Discard()` |

  So on V19 a faceplate must be drawn once in the TIA GUI. On V21 `ExportAsDocuments` +
  `CreateFromDocuments` is a full round-trip, which makes faceplate types generatable and
  diffable like any other document set. `HmiFaceplateContainer` placement and interface
  binding is scriptable on both; a fresh container reads `ContainedType=''` and
  `Interface.Count=0` until it is pointed at a type.

  **Either version still needs a hand-made seed.** `CreateFromDocuments` needs documents,
  and no faceplate schema ships in `Portal V21\Schema` (it holds only IdentManager and
  consistency-message XSDs), so the first faceplate is drawn in the GUI regardless. V21
  then lets you export it, template it, and generate the rest. There is also no
  screen-to-faceplate shortcut: `IMasterCopySource` covers classic `Hmi.Screen.Screen` but
  not Unified screens.
- **The Unified screen generator ports from V19 to V21 unchanged** - verified live in a
  V21 scratch project: `Connect-TiaPortal -Version 21.0 -New` loads the modular assemblies,
  and `New-TiaScreen`, `New-TiaScreenItem` (Rectangle / Text / FaceplateContainer) and the
  `<body><p>..</p></body>` text form all behave identically. Only the panel image version
  changes: `6AV2 128-3QB06-0AXx/21.0.0.0` instead of `/19.0.0.0`.
- **Do not count V21's extra HMI compositions as a benefit until you have used them.**
  `HmiTextLists`, `HmiGraphicLists` and `HmiSystemTextLists` exist on V21's `HmiSoftware`
  and do not exist at all on V19 - but on a fresh V21 project all of them read `<null>`,
  as do `Scripts`, `ScreenGroups` and `PlantObjectTags` (the latter three are null on V19
  too). Presence of a property is not proof of a working API.
- **Git: do not ignore `IM/HMI/`.** On a Unified panel it holds mirrored `Context`/`Saved`
  trees (zips, RDF stores, fonts - about 12 MB) that *look* like staging, but nothing
  proves they regenerate, and the failure mode is a clone that opens with HMI content
  missing while `git status` reads clean. Track it by default. Only `TMP/`, `Logs/`,
  `XRef/`, `UserFiles/` and `IM/SearchIndex/` are demonstrably regenerated; settle any
  other candidate with a clean-clone-and-open test rather than by looking at the files.

---

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `EngineeringSecurityException` on `Connect-TiaPortal` | Not in `Siemens TIA Openness` group, or haven't logged off/on since being added. |
| `Attach` says "Owner ... is not member" | The **target** TIA Portal was started under an old token; restart TIA *after* a full re-login. |
| `new TiaPortal` → "Security error. The operation has timed out." | First-use whitelist dialog can't be shown (e.g. under `runas`); use a real interactive desktop session. |
| Can't load Openness / weird type errors | You're on PowerShell 7. Use Windows PowerShell 5.1. |
| `New-TiaDevice` rejects the order number | MLFB not in your catalog; export an existing device or use a template project. |
| Block import compiles with errors | Check `Invoke-TiaCompile` `.Messages`; SCL interface/name issues are the usual cause. (`.Messages` is already flattened to strings; the nested tree is `.Result.Messages`.) |
| `The type <X> is not permitted in the fail-safe block interface` | The UDT was created from SCL. `IsFailsafeCompliant` is **XML-only** - an SCL-made UDT compiles fine and then fails every F-DB member using it. Same for `ProgrammingLanguage=F_DB` on a GlobalDB. |
| An F-UDT compiles but every certified network fails | A pin/member type mismatch. `DIAG` is a `BYTE`, so it fits no F-compliant member at all - leave it `OpenCon`. See DESIGN-SHEET.md. |
| F-DB rejects a member | `Byte`, `Real`, `String`, ... are not F-compliant. Only `Bool`, `Int`, `DInt`, `Word`, `Time` and nested F-compliant UDTs. |
| `STALE SNAPSHOT: ... has unsynced changes` | The workbook and `design/csv` disagree - run `Sync-TiaDesignSheet`. The build reads the CSV, not the workbook, and `-Force` does not override this gate. |
| `... cannot be accessed. It has already been opened by user ...` | A TIA GUI window holds the project, or a headless run just exited - a project stays locked for ~2 minutes afterwards. |
| `'set_SubnetMask' is not supported by type ... Node` | Expected: an IO **device** inherits its mask from the IO controller. Set it on the controller. |
| Every F-module sits at F-destination address 65534 | Expected: TIA only auto-assigns F-destination addresses through the GUI. Declare them in the design (they must match the BaseUnit DIP switches) - the compiler will **not** flag the collision. |
| `The interface of the standard OB is smaller than the minimum value of 20 bytes` | An OB1 written from SCL with no `VAR_TEMP`. A standard OB needs >= 20 bytes of temp interface; declare the usual `Initial_Call`/`Remanence` plus filler, or import a known-good OB1. |
| `ShouldProcess ... Object reference not set to an instance of an object` | A confirm prompt in a non-interactive host, not an Openness fault. Pass `-Confirm:$false`, or use the API (`$block.Block.Delete()`). Fixed for `Remove-TiaBlock`. |
| `Inputs or outputs are used that do not exist in the configured hardware` | The tags address I/O the CPU does not own - usually IO devices still bound to a **deleted** controller's IO system. Recreate the subnet + IO system on the CPU and reconnect each station (`ConnectToSubnet` + `ConnectToIoSystem`). |
| A saved TIA project shows no change in `git status` | The repo has no `.gitattributes`, so git treated `.ap19`/`.info` as **text** and normalised CRLF - the stored blob is not the file you saved, and status compares the normalised form. Add `* -text` and `git add --renormalize -A`. Committing a TIA project without this silently corrupts it for anyone who clones. |

Run the offline self-test any time to confirm the module itself is healthy:

```powershell
.\tests\Test-Module.ps1
```
