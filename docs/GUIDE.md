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

Screens are authored via XML round-trip:

```powershell
Get-TiaScreen    -Hmi HMI_1
Export-TiaScreen -Hmi HMI_1 -Name Start -Path .\Start.xml   # template / backup
# edit Start.xml ...
Import-TiaScreen -Hmi HMI_1 -Path .\Start.xml -Overwrite
```

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

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `EngineeringSecurityException` on `Connect-TiaPortal` | Not in `Siemens TIA Openness` group, or haven't logged off/on since being added. |
| `Attach` says "Owner ... is not member" | The **target** TIA Portal was started under an old token; restart TIA *after* a full re-login. |
| `new TiaPortal` → "Security error. The operation has timed out." | First-use whitelist dialog can't be shown (e.g. under `runas`); use a real interactive desktop session. |
| Can't load Openness / weird type errors | You're on PowerShell 7. Use Windows PowerShell 5.1. |
| `New-TiaDevice` rejects the order number | MLFB not in your catalog; export an existing device or use a template project. |
| Block import compiles with errors | Check `Invoke-TiaCompile` `.Messages`; SCL interface/name issues are the usual cause. |

Run the offline self-test any time to confirm the module itself is healthy:

```powershell
.\tests\Test-Module.ps1
```
