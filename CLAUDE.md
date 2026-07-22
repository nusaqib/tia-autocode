# CLAUDE.md - tia-autocode engine

Automatic-coding platform for **Siemens TIA Portal** via the **Openness** .NET API.
This repo is the reusable **engine**; specific machines live in **private project repos**
that consume it as a git submodule. See `docs/ROADMAP.md`, `docs/SPECIFICATION.md`,
`docs/GUIDE.md`.

## What this is

A Windows PowerShell 5.1 module (`src/TiaOpenness`) that connects to TIA Portal and
programs it: hardware/devices, tags, UDTs, data blocks, OB/FB/FC logic, HMI - plus a
declarative generator (`Invoke-TiaBuildFromSpec`) that builds a whole project from a
YAML manifest + CSV spreadsheets + SCL files.

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
  scratch project or your own `-New` instance.

## Environment (this machine)

- TIA Portal V19/V20/V21 installed; Openness registered for 19.0 (classic, default) and
  21.0 (modular). The module is version-aware (`Connect-TiaPortal -Version 21.0`).
- Requires membership in the local Windows group **`Siemens TIA Openness`**, activated by
  a **log off/on** (`scripts/Enable-OpennessAccess.ps1`). `GetProcesses` works without it;
  `Attach`/`new TiaPortal` do not.
- No .NET SDK; compiled tooling would use `Framework64\v4.0.30319\csc.exe` (net48).

## Build / test

```powershell
Import-Module .\src\TiaOpenness\TiaOpenness.psd1 -Force   # 41 cmdlets
.\tests\Test-Module.ps1                                   # offline self-test (no TIA)
.\scripts\Validate-Full.ps1                               # live attach + scratch write path
Test-TiaSpec -Path .\examples\example-project\project.yaml
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
- Always `Invoke-TiaCompile` and check `.Errors` before claiming success.

## Skills (in `.claude/skills/`)

`tia-openness` (connection core) - `tia-hardware` (devices/rack/modules) - `tia-data`
(tags/UDTs/DBs) - `tia-programming` (OB/FB/FC) - `tia-hmi` (WinCC) - `tia-autocode`
(spec-driven build). Prefer the module cmdlets; drop to raw `Siemens.Engineering` only
for gaps (see `docs/openness-cheatsheet.md`).

## Git

Repo: `git@github.com:nusaqib/tia-autocode.git`, branch `main`. Commit each coherent unit
and push; keep CI green. Do live/safety writes only with explicit user consent.
