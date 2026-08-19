# CLAUDE.md - tia-autocode engine

Automatic-coding platform for **Siemens TIA Portal** via the **Openness** .NET API.
This repo is the reusable **engine**; specific machines live in **private project repos**
that consume it as a git submodule. See `docs/ROADMAP.md`, `docs/SPECIFICATION.md`,
`docs/GUIDE.md`.

## What this is

A Windows PowerShell 5.1 module (`src/TiaOpenness`) that connects to TIA Portal and
programs it: hardware/devices, tags, UDTs, data blocks, OB/FB/FC logic, HMI - plus two
declarative generators:

- `Invoke-TiaBuildFromSpec` - a whole project from a YAML manifest + CSVs + SCL.
- `Invoke-TiaSheetPipeline` - a whole **safety** project from a design workbook, in eight
  gated phases (Project, Hardware, UDTs, DB, Tags, IOMap, Certified, Interlocks). The
  schema contract is `docs/DESIGN-SHEET.md` (currently **v1.9**); `Test-TiaDesignSheet`
  validates it offline, with no TIA and no network. This is the path SR_PPS uses.

## Hard constraints (do not violate)

- **Windows PowerShell 5.1 (Desktop / .NET FW 4.8) only.** Openness will not load under
  PowerShell 7. Test with `powershell.exe`, not `pwsh`.
- **Source files must be ASCII-only** (`.ps1/.psm1/.psd1`). PS 5.1 reads BOM-less files
  as the ANSI code page, so a stray em-dash/smart-quote breaks parsing on clean machines
  and in CI. `tests/Test-Module.ps1` enforces this - keep hyphens/straight-quotes.
- **Assembly resolution uses a compiled C# handler** (`TiaOpenness.AssemblyResolver`,
  Add-Type) with a `[ThreadStatic]` re-entrancy guard. Do NOT replace it with a
  PowerShell scriptblock resolver - that StackOverflows when Attach()/new TiaPortal()
  load the full runtime.
- **Safety (F) blocks**: never bypass safety access protection. Openness throws
  "permission to modify the safety program is missing" until the user unlocks it in TIA.
- **Never modify a human's live production project** without explicit consent; write to a
  scratch project or your own `-New` instance. `Connect-TiaPortal` with no `-New` ATTACHES
  to whatever GUI session is open - use `-New` for anything that writes or compiles.
- **F-compliant data types are `Bool`, `Int`, `DInt`, `Word`, `Time`** (or a nested UDT
  that is itself F-compliant). Anything else is rejected when the F-DB compiles - phases
  after the mistake was made, with an error naming the type, not the source. Validator
  rule 16 catches it offline. **`Byte` is not F-compliant**, which is why the certified
  `DIAG` output (a `BYTE` on ESTOP1/SFDOOR/EV1oo2DI) cannot be stored in an F-DB at all;
  declaring the member `Bool` instead is worse - the UDT compiles, then every certified
  network fails the connection type check.
- **Fail-safe convention**: at the PLC input `1 = OK`, `0 = fault`. Signal sense, channel
  pairing and interlock membership come from drawings - never from a heuristic, a name
  pattern, or list position.
- **Never wire a safety input to a member nothing writes.** It reads as connected and
  behaves as a constant - worse than an open pin, which at least looks unfinished.

## Environment (this machine)

- TIA Portal V19/V20/V21 installed; Openness registered for 19.0 (classic, default) and
  21.0 (modular). The module is version-aware (`Connect-TiaPortal -Version 21.0`).
- Requires membership in the local Windows group **`Siemens TIA Openness`**, activated by
  a **log off/on** (`scripts/Enable-OpennessAccess.ps1`). `GetProcesses` works without it;
  `Attach`/`new TiaPortal` do not.
- No .NET SDK; compiled tooling would use `Framework64\v4.0.30319\csc.exe` (net48).

## Build / test

```powershell
Import-Module .\src\TiaOpenness\TiaOpenness.psd1 -Force   # 64 cmdlets
.\tests\Test-Module.ps1                                   # offline self-test (no TIA)
.\scripts\Validate-Full.ps1                               # live attach + scratch write path
Test-TiaSpec -Path .\examples\example-project\project.yaml
Test-TiaDesignSheet -Path <repo>\design\csv                # sheet schema + safety rules
```
CI (`.github/workflows/ci.yml`, windows-latest) runs the offline self-test on every push.
When CI fails and logs are admin-gated, read `::error::` annotations at
`GET /repos/nusaqib/tia-autocode/commits/<sha>/check-runs`.

## Module layout & conventions

- `Private/` helpers (assembly resolver, session state, YAML reader, SCL synthesizers).
  `Public/` exported cmdlets - the loader auto-discovers them; add new names to
  `TiaOpenness.psd1` `FunctionsToExport`. The self-test asserts manifest == exports.
- Cmdlets are verb-noun; `-Plc`/`-Hmi` accept a wrapper, raw software object, name, or
  nothing (first). Use `Get-Safe { }` for optional Openness props inside hashtables.
- SCL-first authoring (portable, diffable); SimaticML XML for graphical/exact blocks.
  Two things are **XML-only and cannot be set from SCL**: a UDT's `IsFailsafeCompliant`
  and a GlobalDB's `ProgrammingLanguage=F_DB`. Both fail silently at creation and loudly
  two phases later.
- Always `Invoke-TiaCompile` and check `.Errors` before claiming success. `Invoke-TiaCompile`
  returns `.Messages` already flattened to strings; the nested message tree is `.Result.Messages`.
- **HMI: check `SoftwareType`, not the panel's name.** A *Unified Comfort Panel*
  (`6AV2 128-*`) is `HmiUnified.HmiSoftware`, not a classic Comfort `Hmi.HmiTarget`. On
  Unified there is **no `ScreenFolder`** and **no screen XML** (`HmiScreen` has only
  `Delete()`), so `Export-/Import-TiaScreen` do not apply; screens are built from objects
  with `New-TiaScreen`/`New-TiaScreenItem`/`Set-TiaScreenItemTag`. Their `Create<T>()` is
  generic (needs `MakeGenericMethod`), and item `Left`/`Top` are `Int32` while
  `Width`/`Height` are `UInt32`. Details and the rest of the traps: `docs/GUIDE.md` 11.7.
- **On Unified, `New-TiaHmiTag` does not work** (it reports the flavor as `Object[]`) - use
  `HmiTagTable.Tags.Create(name)`, and **never set `DataType`**: assign `Connection` then
  `PlcTag` and TIA resolves the type, while assigning it explicitly throws "Empty data type
  or HMI data type at tag ...". One UDT-typed tag per area makes the whole DB reachable by
  path. Button captions are rich text like `HmiText`; navigation is
  `EventHandlers.Create(...Tapped)` then `.Script.ScriptCode` (`Script` itself is
  read-only), and the call is `HMIRuntime.UI.SysFct.ChangeScreen('<screen>','~')` -
  `SysFct` not `SysFn`; the valid verbs are listed in `WinCCUnified/bin/_config/IOWA_*.xml`. **V19 exposes no start-screen property** - a generated hierarchy is
  unreachable until the start screen is repointed in the GUI.
- **The Openness surface differs by version - check the assembly, not your memory.** V21 is
  modular (`Siemens.Engineering.Base/.WinCC/.WinCCUnified.dll`) and adds what V19 lacks:
  `LibraryTypeComposition.CreateFromDocuments` + `FaceplateLibraryTypeVersion
  .ExportAsDocuments` (so faceplate types are generatable on V21, not on V19), HMI text and
  graphic lists, scripts, screen groups, `HmiScreen.Validate()`, and 45 screen-item types
  against V19's 38. Reflect over the version you are bound to before declaring a limit.
- **Do not gitignore `IM/HMI/` in a committed TIA project.** It looks like build output
  (mirrored `Context`/`Saved` trees of zips, RDF stores and fonts, ~12 MB) but nothing
  proves it regenerates, and the failure mode is a clone that opens with HMI content
  missing while `git status` reads clean. Track by default; only `TMP/`, `Logs/`, `XRef/`,
  `UserFiles/` and `IM/SearchIndex/` are *demonstrably* regenerated. Settle any other
  candidate with a clean-clone-and-open test, not by inspection.

## Design-sheet pipeline

`design/<workbook>.xlsx` (authoring surface) -> `Sync-TiaDesignSheet` -> `design/csv/`
(committed snapshot, the actual build input) -> `Test-TiaDesignSheet` (offline gate) ->
`Invoke-TiaSheetPipeline` -> TIA. The CSV snapshot is what `git diff` reviews, so it is
the safety change record; the workbook is a binary blob and diffs to nothing. A phase
refuses to run on a stale snapshot, and `-Force` does not override that.

Openness limits here, all discovered live - do not re-spike:

- **F-DI sensor evaluation (1oo1/1oo2) has no attribute - but it CAN still be changed.**
  Verified across all 42 F-DI: 1oo1 and 1oo2 modules expose an *identical* 57-attribute
  set, no `Discrepancy*`/`*Evaluation*` attribute exists, ~90 candidate names return
  nothing from a direct `GetAttribute`, and `GetService<GsdDeviceItem>`/`<AddressController>`
  are both null. Two things follow:
  - **It is READABLE** as `Failsafe_FParameterSignatureWithoutAddresses`, a
    per-configuration fingerprint. For `6ES7 136-6BA01-0CA0`: `19180` = 1oo2, `40925` = 1oo1.
    (`Failsafe_FParameterSignatureIndividualParameters` also moves but varies per module -
    use the WithoutAddresses one.)
  - **It is SETTABLE BY REPLACEMENT**: configure ONE module by hand in the GUI, then
    `rack.PlugCopy($source, $slot)` over every other module of the SAME order number. The
    copy carries the channel parameterisation. Proven on 36 modules; compiles 0 errors.

  Three hazards, all hit live - handle them or the change is silently wrong:
  - `PlugCopy` does **not** carry `Failsafe_FDestinationAddress`; TIA assigns a fresh one.
    Read it before, write it back after.
  - Delete-then-replug can **reassign input addresses** (12 of 34 jumped to the top of the
    address space). `Address.StartAddress` on the module's *head sub-item* is writable -
    capture every base before, restore and re-check for overlaps after.
  - **Never copy across order numbers** - it silently changes the part number. Match on
    `OrderNumber` and verify it again afterwards.
- **F-destination addresses are never auto-assigned through Openness.** Every F-module
  keeps the catalogue default (65534) and the compiler does not object - they collide
  silently. They must be declared in the sheet to match the BaseUnit DIP switches.
- **An IO device inherits `SubnetMask` from its IO controller** (`set_SubnetMask is not
  supported`). Report it as inherited, not as a failure.
- **A simulated F-CPU has no PROFIsafe I/O.** PLCSIM/PLCSIM Advanced never connect an
  F-module, so all of them passivate and the input image is substituted with 0 - under
  `1 = OK` everything reads fault. Testing the logic needs safety mode deactivated AND the
  IOMap layer not running (it rewrites the DB members every scan), in a throwaway copy.
  See `docs/GUIDE.md` 11.6.
- **A TIA project committed to git needs `.gitattributes` with `* -text`.** Otherwise git
  treats `.ap19`/`.info` as text, normalises CRLF, and stores a blob that is not the file
  that was saved - while `git status` reads clean.

## Skills (in `.claude/skills/`)

`tia-openness` (connection core) - `tia-hardware` (devices/rack/modules) - `tia-data`
(tags/UDTs/DBs) - `tia-programming` (OB/FB/FC) - `tia-hmi` (WinCC) - `tia-autocode`
(spec-driven build). Prefer the module cmdlets; drop to raw `Siemens.Engineering` only
for gaps (see `docs/openness-cheatsheet.md`).

## Git

Repo: `git@github.com:nusaqib/tia-autocode.git`, branch `main`. Commit each coherent unit
and push; keep CI green. Do live/safety writes only with explicit user consent.
