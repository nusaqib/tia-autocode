---
name: tia-autocode
description: Generate a complete TIA Portal program from a declarative spec - a YAML manifest plus CSV spreadsheets (tags, UDTs, DBs, modules) and SCL logic files, built and compiled by Invoke-TiaBuildFromSpec. Use for spreadsheet-driven / spec-driven project generation, the manifest/project.yaml, Test-TiaSpec validation, or setting up a private project repo that consumes the engine. Orchestrates the tia-hardware, tia-data, and tia-programming skills.
---

# tia-autocode: spec-driven project generation

The automatic-coding layer. Author a project as data + SCL; the engine generates it.
See `docs/ROADMAP.md` (plan + contracts) and `examples/example-project/` (working spec).

## Architecture

- **Engine** (this public repo): the `TiaOpenness` module + generator + validator.
- **Project repos** (private, one per machine): the specs, consuming the engine as a
  **git submodule**. Customer data never lives in the engine.

Scaffold a project repo with **`New-TiaProjectRepo -Path .\my-machine -Name MyMachine`**:
it copies the built-in `project-template` (manifest, starter data/logic, `build.ps1`,
`validate.ps1`, offline-validation CI, `.gitignore`, README) and fills in the name, then
prints the `git submodule add ... engine` steps. Offline.

## Workflow

1. Author tabular data in **Google Sheets**, then `File -> Download -> CSV` per tab into
   the project's `data/` folder (git-versioned, fully private).
2. Write FB/FC/OB as **SCL** in `logic/`.
3. Describe it all in `project.yaml` (the manifest).
4. **Validate offline**, then build:
   ```powershell
   Import-Module .\engine\src\TiaOpenness\TiaOpenness.psd1 -Force
   Test-TiaSpec -Path .\project.yaml         # no TIA needed; fail fast
   Invoke-TiaBuildFromSpec -Path .\project.yaml
   ```

## Manifest (project.yaml)

```yaml
project: { name: MyMachine, path: C:\work\MyMachine }
portal:  { new: true, ui: false }
plcs:
  - name: PLC_1
    orderNumber: "OrderNumber:6ES7 515-2FM02-0AB0/V2.9"
    modules: [ data/PLC_1.modules.csv ]
    udts:    [ data/PLC_1.udts.csv ]
    dbs:     { blocks: data/PLC_1.dbs.blocks.csv, members: data/PLC_1.dbs.members.csv }
    logic:   [ logic/FC_Scale.scl, logic/FB_MotorStarter.scl, logic/OB_Main.scl ]
    tags:    [ data/PLC_1.tags.csv ]
    compile: true
build: { snapshotDir: generated, save: false }
```
Manifest may be `.yaml`/`.yml` (bundled reader) or `.json`.

## Build order (per PLC)

device -> modules -> UDTs -> DBs -> logic (SCL) -> tags -> compile -> snapshot -> save.
`Invoke-TiaBuildFromSpec` returns `{ Ok, Steps, Errors }`; per-item failures are
collected, not fatal. `save:false` leaves the project unsaved for review.

## Validate before you build

`Test-TiaSpec` (offline, CI-friendly) checks: files exist; required CSV columns; tag
addresses well-formed; names unique; module slots unique integers; and that UDT/FB
references and datatypes resolve. Returns `{ Ok, Errors, Warnings }`; run it in the
project repo's CI.

## Authoring helpers (Phase 4)

- **XLSX instead of CSV**: any tabular ref may be `data/book.xlsx#SheetName`. Reading is
  dependency-free (`Import-TiaXlsx` parses OOXML; no Excel/COM), so CI stays clean.
- **Naming lint**: add a `naming:` section (pattern/prefix/suffix/maxLength/case per kind
  - tags/udts/dbs/fbs/fcs/hmiTags/modules). `Test-TiaNaming -Path` reports violations;
  `Test-TiaSpec` folds them into Warnings. Standalone: also accepts `-Rules <file|hashtable>`.
- **Templates**: `Get-TiaTemplate` / `Expand-TiaTemplate` instantiate reusable SCL/UDT
  templates (`{{Token}}` + `@param name[=default]`). Built-ins: MotorStarter (FB),
  AnalogScale (FC), CommandStatus (UDT). In a spec, a `logic` entry may be
  `{ template: MotorStarter, params: { Name: FB_Conveyor } }` (optionally `templateDir`
  for a project-local library). `Test-TiaSpec` expands templates to resolve InstanceOfFB
  / TypedOfUDT references.

## Delegates to the area skills

- Hardware/rack -> `tia-hardware`
- Tags/UDTs/DBs -> `tia-data`
- OB/FB/FC logic -> `tia-programming`
- HMI -> `tia-hmi`
- Connection/session basics + safety rules -> `tia-openness`

## Reverse: adopt an existing project (`Export-TiaToSpec`)

Turn a live PLC into an editable spec folder - tags + modules as CSV, UDTs + blocks as
SimaticML XML, and a rebuildable `project.json`:

```powershell
Connect-TiaPortal
Export-TiaToSpec -OutDir .\adopted\MyMachine -PlcName PLC_1
# -> data/*.tags.csv, data/*.modules.csv, types/*.xml, blocks/*.xml, project.json
```

It splits the CPU (`orderNumber`) from the rail and pluggable modules, and skips
know-how/safety-protected blocks with a warning. Rebuild from the export with
`Invoke-TiaBuildFromSpec -Path .\adopted\MyMachine\project.json` (imports `typesXml`
into the TypeGroup and `blocksXml` into the BlockGroup). Great for version-controlling
an existing machine and diffing changes.

## Safety

Do generation against your own `-New` instance or a scratch project. Safety (F) blocks
require the TIA safety program to be unlocked; the engine never bypasses that. The
generated project is only persisted when `build.save: true` (else it opens empty).
