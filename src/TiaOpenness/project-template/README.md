# {{MachineName}}

TIA Portal project for **{{MachineName}}**, generated from a declarative spec by the
[tia-autocode](https://github.com/nusaqib/tia-autocode) engine, consumed here as a git
submodule at `engine/`. All machine data lives in this (private) repo; the engine stays
public and generic.

## First-time setup

```powershell
git submodule add https://github.com/nusaqib/tia-autocode.git engine
git submodule update --init --recursive
```

## Author the machine

> **See [AUTHORING.md](AUTHORING.md)** for the full reference: what to specify and in
> which file (every `project.yaml` field + every CSV column), datatypes/addresses, HMI,
> naming rules, and how to create another project from the template.

- **Data** in `data/*.csv` - tags, UDTs, DBs (blocks + members), rack modules, HMI tags.
  A workbook works too: reference a sheet as `data/PLC_1.xlsx#Tags`.
- **Logic** in `logic/*.scl` (FB/FC/OB), or instantiate an engine template in the
  manifest: `logic: [ { template: MotorStarter, params: { Name: FB_Conveyor } } ]`
  (`Get-TiaTemplate` lists what is available).
- **Hardware/HMI**: set your CPU and panel order numbers in `project.yaml`.
- **Naming**: the `naming:` section lints object names (advisory warnings).

## Validate (offline - no TIA, runs in CI)

```powershell
powershell -ExecutionPolicy Bypass -File .\validate.ps1
```

## Build (needs Windows + TIA Portal + Openness)

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Generates the project under `_out/{{MachineName}}` (gitignored) and compiles it.

## CI

`.github/workflows/validate.yml` checks out the engine submodule and runs
`validate.ps1` on every push/PR - fast, offline spec validation. Keep it green.

## Layout

```
{{MachineName}}/
  engine/            git submodule -> tia-autocode (pinned commit)
  project.yaml       the manifest
  data/              CSV/XLSX exported from your spreadsheets (versioned)
  logic/             SCL - the code
  hmi/               HMI screen/tag/alarm XML (round-tripped from TIA)
  generated/         build snapshots for diffing (gitignored)
  build.ps1 / validate.ps1
```
