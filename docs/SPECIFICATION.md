# tia-autocode — Specification

Repository: `git@github.com:nusaqib/tia-autocode.git`
Component: **`TiaOpenness`** PowerShell module + declarative generator + skills.

---

## 1. Purpose

`tia-autocode` is an automatic-coding platform for **Siemens TIA Portal**. It drives
TIA Portal through its **Openness** .NET API to programmatically create and manage the
contents of a PLC/HMI project — devices, tags, data types, data blocks, logic blocks
(FC/FB/OB), HMI screens — and to compile, export, and download them. The goal is to
treat automation programs as **code and data**: reproducible, diff-able, version-
controlled, and generated from declarative specs rather than hand-clicked in the IDE.

### Design principles

- **No build step for the driver.** Openness is a .NET Framework 4.8 API; the platform
  is a Windows PowerShell 5.1 module that reflection-loads it. Nothing to compile.
- **Text-first authoring.** Logic is authored as **SCL** (compiled into blocks via
  external-source generation) — portable, diffable, CPU-model-agnostic. Graphical or
  exact-layout blocks use **SimaticML XML**.
- **Version-aware.** Supports the V19 classic single-DLL API (default) and the V21
  modular API; resolves the correct assemblies from the registry.
- **Safety by default.** Attaching to a human's live session is read-oriented; writes
  target a scratch project or a dedicated instance. Hardware-affecting actions
  (download, delete) are guarded by `ShouldProcess`.
- **Discovery-first for HMI.** WinCC collections vary by flavor/version, so the HMI
  layer inspects the live object model before scripting it.

---

## 2. Requirements & environment

| Requirement | Detail |
|---|---|
| OS | Windows 10/11 |
| TIA Portal | V19 (classic Openness) and/or V21 (modular). V20 present but Openness not registered on the reference machine. |
| Runtime | **Windows PowerShell 5.1** (Desktop / .NET FW 4.8). PowerShell 7 (Core) cannot load Openness. |
| Windows group | Caller **must** be in local group **`Siemens TIA Openness`**; membership requires a **log off/on** to take effect. |
| Openness assemblies | Resolved from `HKLM\SOFTWARE\Siemens\Automation\Openness\<ver>`; V19 → `Siemens.Engineering.dll`, V21 → `Siemens.Engineering.Base.dll` (+ Step7/Hmi). |
| Optional build tooling | `csc.exe` / MSBuild at `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` (net48) for future compiled tools; no .NET SDK required. |

See [openness-cheatsheet.md](openness-cheatsheet.md) for the raw API details and
[../scripts/Enable-OpennessAccess.ps1](../scripts/Enable-OpennessAccess.ps1) for the
group setup.

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 3  Declarative generator   Invoke-TiaBuildFromSpec      │  JSON spec → program
├─────────────────────────────────────────────────────────────┤
│ Layer 2  Cmdlet API (Public/)    37 verb-noun commands        │  object-model wrappers
│          Connect · Project · Tags · Types · Blocks ·          │
│          Organization · Hmi · Lifecycle · Build               │
├─────────────────────────────────────────────────────────────┤
│ Layer 1  Connection & resolution (Private/)                   │  registry-driven
│          TiaAssembly (resolver) · TiaState (session/helpers)  │  assembly loading
├─────────────────────────────────────────────────────────────┤
│ Siemens.Engineering (Openness .NET API)  ↔  TIA Portal        │
└─────────────────────────────────────────────────────────────┘
```

### Module layout

```
src/TiaOpenness/
  TiaOpenness.psd1          manifest (declares the 37 exported functions)
  TiaOpenness.psm1          loader: dot-sources Private then Public, auto-exports
  Private/
    TiaAssembly.ps1         version discovery, AssemblyResolve handler, load
    TiaState.ps1            current portal/project state, Get-Safe, resolvers
  Public/
    Connect-TiaPortal.ps1   sessions
    Project.ps1             projects, devices, PLC discovery
    Tags.ps1                tag tables & tags
    Types.ps1               UDTs & data blocks
    Blocks.ps1              logic blocks, SCL/XML import, export, compile
    Organization.ps1        block folders, OB, delete
    Hmi.ps1                 WinCC discovery, screens
    Lifecycle.ps1           export program, online state, download
    Build.ps1               Invoke-TiaBuildFromSpec
```

---

## 4. Feature matrix

| Domain | Capability | Cmdlets | Status |
|---|---|---|---|
| **Setup/diag** | List installed Openness versions; report loaded state | `Get-TiaInstalledVersion`, `Get-TiaOpennessState` | ✅ validated |
| **Session** | Enumerate running Portals; attach; start headless/UI; detach/close | `Get-TiaSession`, `Connect-TiaPortal`, `Disconnect-TiaPortal` | ✅ validated (enum + attach + headless start) |
| **Project** | Create / open / get / save / close | `New-TiaProject`, `Open-TiaProject`, `Get-TiaProject`, `Save-TiaProject`, `Close-TiaProject` | ✅ validated (create + save) |
| **Hardware** | Add CPU by order number; enumerate PLCs (SoftwareContainer) | `New-TiaDevice`, `Get-TiaPlc` | ✅ validated (added S7-1515F; read live PLC) |
| **Tags** | Create/list tag tables & tags (type, address, comment) | `Get-/New-TiaTagTable`, `Get-/New-TiaTag` | ✅ validated (created + read) |
| **Data types** | Create/list UDTs from SCL `TYPE...END_TYPE` | `Get-TiaType`, `New-TiaType` | ☑ implemented (SCL path shared with blocks) |
| **Data blocks** | Global DB from SCL; instance/typed DB "of" FB/UDT | `New-TiaDataBlock` | ☑ implemented |
| **Logic blocks** | FC/FB/OB from SCL text or `.scl`; SimaticML XML import; export | `Import-TiaScl`, `New-TiaOb`, `Import-TiaBlockXml`, `Export-TiaBlock`, `Get-TiaBlock` | ✅ validated (imported FC+FB; read blocks) |
| **Compile** | Compile a block or whole PLC; structured result | `Invoke-TiaCompile` | ✅ validated (0 errors / 0 warnings) |
| **Organization** | Nested block folders; delete blocks | `New-/Get-TiaBlockGroup`, `Remove-TiaBlock` | ☑ implemented |
| **HMI** | Create panels; discover HMI software; introspect API; screens/tag-tables/alarms XML round-trip; tags + connections | `New-TiaHmiDevice`, `Get-TiaHmi`, `Show-TiaHmiApi`, `Get-TiaScreen`, `Export-/Import-TiaScreen`, `Get-TiaHmiConnection`, `Get-/New-TiaHmiTag`, `Export-/Import-TiaHmiTagTable`, `Export-/Import-TiaHmiAlarms` | ◐ panel creation validated live (KTP700 Comfort); screen/tag/alarm XML wrappers offline-tested |
| **Lifecycle** | Export whole program to XML; online state; guarded download | `Export-TiaProgram`, `Get-TiaOnlineState`, `Invoke-TiaDownload` | ☑ implemented (download needs online CPU/PLCSIM) |
| **Generator** | Build a full program from a JSON spec | `Invoke-TiaBuildFromSpec` | ☑ implemented (composes validated cmdlets) |
| **Quality** | Offline structural self-test; CI on windows-latest | `tests/Test-Module.ps1` | ✅ passing |

Legend: ✅ validated end-to-end against the live V19 session (2026-07-21) ·
☑ implemented and loads, not yet exercised against live hardware/HMI.

---

## 5. Cmdlet reference

Common conventions:
- `-Plc` accepts a `Get-TiaPlc` result, a raw `PlcSoftware`, a PLC name, or nothing
  (defaults to the first PLC). `-Hmi` behaves the same via `Get-TiaHmi`.
- Commands operate on the module's *current* portal/project unless you pass explicit
  `-Portal`/`-Project`.

### 5.1 Setup / diagnostics
- **`Get-TiaInstalledVersion`** → one row per registered Openness version: `Version`,
  `Major`, `IsModular`, `EngineeringDll`, `PublicKeyToken`, `AssemblyVersion`.
- **`Get-TiaOpennessState`** → `Loaded`, `Version`, `EngineeringDll`, `SearchDirs`.

### 5.2 Session
- **`Get-TiaSession [-Version]`** → running Portals: `Id`, `ProjectPath`, `Mode`,
  `AttachTime`. Works without the Openness group.
- **`Connect-TiaPortal [-ProcessId n] [-New] [-WithUserInterface $true|$false] [-Version]`**
  → attach to a running Portal (default) or start a new one. Adopts an already-open
  project as current. Returns `Version`, `StartedByUs`, `OpenProjects`, `Portal`.
- **`Disconnect-TiaPortal [-Close]`** → detach; `-Close` disposes an instance you
  started (guards against closing a human's session).

### 5.3 Project & hardware
- **`New-TiaProject -Name -Path [-Portal]`** → create + set current.
- **`Open-TiaProject -ProjectFile [-Portal]`** → open `.apXX` + set current.
- **`Get-TiaProject [-All]`** / **`Save-TiaProject`** / **`Close-TiaProject [-NoSave]`**.
- **`New-TiaDevice -TypeIdentifier -Name [-DeviceItemName]`** → add a CPU; identifier
  is `OrderNumber:<MLFB>/<FW>` (see [adding-a-device.md](adding-a-device.md)).
- **`Get-TiaPlc [-Name]`** → CPUs as `{Name, Device, DeviceItem, PlcSoftware}`.

### 5.4 Tags
- **`Get-TiaTagTable [-Name] [-Plc]`** → `{Name, Group, TagCount, TagTable}` (recursive).
- **`New-TiaTagTable -Name [-Plc]`** → idempotent create.
- **`Get-TiaTag [-TagTable] [-Name] [-Plc]`** → `{Name, DataType, Address, Table, Comment}`.
- **`New-TiaTag -Name -DataType -Address [-TagTable] [-Comment] [-Plc]`** → creates the
  table if missing. Addresses like `%I0.0`, `%Q0.1`, `%MW20`, `%DB1.DBX0.0`.

### 5.5 Data types & data blocks
- **`Get-TiaType [-Name] [-Plc]`** → UDTs (recursive).
- **`New-TiaType (-Scl | -Path) [-Name] [-KeepSource] [-Plc]`** → UDT from `TYPE…END_TYPE`.
- **`New-TiaDataBlock (-Scl | (-Name -OfType)) [-KeepSource] [-Plc]`** → global DB from
  SCL, or an instance/typed DB of an FB/UDT.

### 5.6 Logic blocks
- **`Get-TiaBlock [-Name] [-Type OB|FB|FC|GlobalDB|InstanceDB|Any] [-Plc]`** →
  `{Name, Type, Number, Language, Group, Modified, Block}` (recursive).
- **`Import-TiaScl (-Scl | -Path) [-Name] [-KeepSource] [-Plc]`** → creates/updates one
  or more blocks by registering an external source and generating blocks from it.
- **`New-TiaOb -Scl [-KeepSource] [-Plc]`** → OB (e.g. `ORGANIZATION_BLOCK "Main"`).
- **`Import-TiaBlockXml -Path [-Overwrite] [-Plc]`** → SimaticML import (LAD/FBD/STL/SCL).
- **`Export-TiaBlock -Name -Path [-Overwrite] [-Plc]`** → SimaticML export.
- **`Invoke-TiaCompile [-BlockName] [-Plc]`** → compile block or PLC; returns
  `{State, Warnings, Errors, Messages}`.

### 5.7 Organization
- **`New-TiaBlockGroup -Path [-Plc]`** → nested folder (`'Motion/Axes'`), idempotent.
- **`Get-TiaBlockGroup [-Plc]`** → `{Path, BlockCount, Group}`.
- **`Remove-TiaBlock -Name [-Plc]`** → delete (SupportsShouldProcess, High impact).

### 5.8 HMI (see the `tia-hmi` skill)
- **`Get-TiaHmi [-Name]`** → HMI software: `{Name, Device, SoftwareType, HmiSoftware}`.
- **`Show-TiaHmiApi [-Hmi]`** → reflection dump of the HMI object's properties/collections.
- **`Get-TiaScreen [-Name] [-Hmi]`** → screens (recursive).
- **`Export-TiaScreen -Name -Path [-Overwrite] [-Hmi]`** / **`Import-TiaScreen -Path [-Overwrite] [-Hmi]`**.
- **`New-TiaHmiDevice -OrderNumber -Name [-DeviceItemName]`** → adds a WinCC panel from
  a catalog order number (CreateWithItem). Live-validated: KTP700 Comfort
  `OrderNumber:6AV2 124-1GC01-0AX0/17.0.0.0`. Returns the `Get-TiaHmi` wrapper.
- **`Get-TiaHmiConnection [-Name] [-Hmi]`** → connections `{Name, Type, Connection}`.
- **`Get-TiaHmiTag [-Name] [-TagTable] [-Hmi]`** → HMI tags across tables.
- **`New-TiaHmiTag -Name [-DataType] [-Connection] [-PlcTag] [-Address] [-Acquisition] [-Comment] [-TagTable] [-Hmi]`**
  → creates/updates an HMI tag (discovery-first; internal tag when `-Connection` omitted).
- **`Export-/Import-TiaHmiTagTable`** and **`Export-/Import-TiaHmiAlarms -Kind Discrete|Analog`**
  → schema-exact SimaticML round-trip for tag tables and alarms.

### 5.9 Lifecycle
- **`Export-TiaProgram -OutDir [-IncludeTags] [-Plc]`** → export every block (and
  optionally tag tables) to XML — a diffable snapshot. Returns counts.
- **`Get-TiaOnlineState [-Plc]`** → `{State, Connected}`.
- **`Invoke-TiaDownload [-Force] [-Plc]`** → download to CPU. **Hardware-affecting**;
  SupportsShouldProcess (`-WhatIf`/`-Confirm`), requires an online connection
  (real CPU or PLCSIM). Adapt the pre/post delegates to your setup.

### 5.10 Generator
- **`Invoke-TiaBuildFromSpec (-Path | -Spec) [-BaseDir]`** → see §6. Returns
  `{Ok, Steps[], Errors[]}`; per-item failures are collected, not fatal.

---

## 6. Declarative spec schema

`Invoke-TiaBuildFromSpec -Path .\specs\demo.json`. All sections optional.

```jsonc
{
  "portal":  { "new": true, "ui": false },        // start headless; omit to attach
  "project": { "name": "Demo",                     // create or (openIfExists) open
               "path": "Demo",                      // relative to the spec file
               "openIfExists": true },
  "plcs": [{
    "name": "PLC_1",
    "orderNumber": "OrderNumber:6ES7 512-1SN03-0AB0/V3.0",  // added if absent
    "tagTables": [{
      "name": "IO",
      "tags": [
        { "name":"Start_PB", "dataType":"Bool", "address":"%I0.0", "comment":"start" }
      ]
    }],
    "types":  [ { "scl":"TYPE \"MotorData\" STRUCT Speed:Real; END_STRUCT; END_TYPE" },
                { "sclFile":"types\\Foo.udt" } ],
    "blocks": [ { "sclFile":"..\\templates\\Scale.scl" },
                { "scl":"FUNCTION_BLOCK \"MotorStarter\" ... END_FUNCTION_BLOCK" } ],
    "dataBlocks": [ { "name":"Motor1_DB", "ofType":"MotorStarter" },
                    { "scl":"DATA_BLOCK \"Settings\" ... END_DATA_BLOCK" } ],
    "compile": true
  }],
  "hmis": [ { "name":"HMI_1",
              "tags":["data\\HMI_1.hmitags.csv"],
              "alarms":[ { "kind":"Discrete", "importXml":"hmi\\DiscreteAlarms.xml" } ],
              "screens":[ { "importXml":"screens\\Start.xml" } ] } ],
  "save": true
}
```

Execution order: portal → project → for each PLC (device → modules → UDTs → logic →
DBs → tags → compile → snapshot) → for each HMI (tagTablesXml → tags CSV → alarms →
screens) → save. Relative paths resolve against `-BaseDir` (defaults to the spec
file's folder).

---

## 7. Safety model

- **Live sessions are treated as read-oriented.** Writes should target a scratch
  project or an instance you started (`Connect-TiaPortal -New`).
- **Never modify the user's production project** (`PPS_SR_`) without explicit consent.
- **Guarded mutations.** `Remove-TiaBlock` and `Invoke-TiaDownload` implement
  `ShouldProcess` — support `-WhatIf`/`-Confirm`.
- **`Disconnect-TiaPortal -Close`** only disposes instances started with `-New`.
- **Compile before claiming success**; check `Invoke-TiaCompile` errors.

---

## 8. Quality & CI

- **`tests/Test-Module.ps1`** — offline structural test (no TIA needed): module load,
  manifest ⇄ export agreement, help coverage on all cmdlets, core-cmdlet presence,
  demo-spec schema, version detection (skipped where TIA absent). Exits non-zero on fail.
- **`.github/workflows/ci.yml`** — runs the self-test on `windows-latest` per push/PR.

---

## 9. Limitations & roadmap

Current limitations:
- **Validated end-to-end** on the reference machine (2026-07-21): live attach + read
  of `PPS_SR_`, and a full write path (project -> S7-1515F CPU -> tags -> SCL FC/FB ->
  compile, 0 errors). Remaining items below are the not-yet-live-exercised pieces.
- **`Invoke-TiaDownload`** pre/post delegates are a scaffold - real downloads may need
  per-configuration decisions (stop modules, overwrite) tailored to the setup.
- **HMI panel creation** (`New-TiaHmiDevice`, and the `hmis[].orderNumber` spec key) is
  **validated live** (KTP700 Comfort on V19). **HMI tag creation via the API is not
  possible on WinCC Comfort/Advanced** - the `TagComposition` exposes only
  `CreateFrom(MasterCopy)` and the tag DataType is a typed link, not a string - so
  `New-TiaHmiTag` works only on flavors that expose a tag `Create`; on Comfort, author
  tags via tag-table XML import (`Import-TiaHmiTagTable`). The build treats CSV HMI tags
  on such flavors as validated-but-deferred (a note, not a failure).
- **HMI tag-table/alarm/screen XML round-trip** wrappers are reflection-based and
  offline-tested; validate on a scratch panel before running against anything live.
- **SimaticML XML** authoring is schema/version-specific; export a real block to learn
  the exact shape.

Roadmap candidates:
- Live-validate the HMI tag/connection/alarm cmdlets against a real Comfort/Unified panel.
- LAD/FBD network builders emitting SimaticML.
- PLCSIM integration for automated compile+download+test loops.
- Safety (F) program helpers via `Siemens.Engineering.Safety`.
- YAML specs and a spec JSON-schema for editor validation.
- Round-trip: `Import-TiaProgram` (bulk XML import) to complement `Export-TiaProgram`.

---

## 10. Glossary

| Term | Meaning |
|---|---|
| Openness | Siemens' .NET automation API for TIA Portal (`Siemens.Engineering`). |
| PlcSoftware | The programmable surface of a CPU (tags, blocks, types). |
| SCL | Structured Control Language — text PLC language (IEC ST dialect). |
| SimaticML | Openness XML representation of blocks/screens for import/export. |
| MLFB / order number | Siemens catalog identifier for a device (e.g. `6ES7 512-1SN03-0AB0`). |
| FC / FB / OB / DB | Function / Function Block / Organization Block / Data Block. |
| UDT | User-Defined (PLC data) Type. |
| HmiTarget | WinCC Comfort/Advanced HMI runtime object. |
