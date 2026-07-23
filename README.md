# TIA_API — Siemens TIA Portal automatic coding platform

> **Status: validated end-to-end (2026-07-21).** Attached to a live V19 project, read
> its devices/tags/blocks, and generated a scratch program (CPU → tags → SCL FC/FB →
> compile, **0 errors**). Repo: `github.com/nusaqib/tia-autocode` · CI: green.

Connect to a running (or headless) **Siemens TIA Portal** session through the
**Openness** API and program PLCs from code: sessions, projects, devices, tags,
tag tables, and logic blocks (FC / FB / OB) including **SCL routines**, then compile.

The driver is a Windows PowerShell 5.1 module, **`TiaOpenness`**, chosen because
Openness is a .NET Framework 4.8 API and this machine has no .NET SDK — PowerShell
reflection-loads the API with zero build step. Compiled tooling can be added later
via the Framework `csc.exe` / MSBuild (net48).

## Status

| Piece | State |
|-------|-------|
| Environment probe (versions, DLLs, group, live session) | ✅ validated |
| Module: connect / project / device / tags / types / DBs / blocks / HMI / compile / export / download | ✅ built, loads, **55 cmdlets** exported |
| Declarative generator (`Invoke-TiaBuildFromSpec`) - YAML manifest + CSV/XLSX + SCL | ✅ built, live-validated (compile 0 errors) |
| Reverse adoption (`Export-TiaToSpec`) | ✅ built, live-validated |
| Authoring helpers - XLSX import, naming lint, SCL/UDT templates | ✅ built, live-validated |
| Project-repo scaffolder (`New-TiaProjectRepo`) + git-submodule template | ✅ built, self-tested |
| Session enumeration (`GetProcesses`) | ✅ validated against live V19 session |
| Group membership (`Siemens TIA Openness`) | ✅ user added + activated (log off/on) |
| **Attach + read live project** | ✅ validated — attached to `PPS_SR_`, read devices/tags/blocks |
| **Write path (project → CPU → tags → SCL FC/FB → compile)** | ✅ validated — compiled 0 errors / 0 warnings |

The roadmap (Phases 0-5) is **complete**: spec-driven build, reverse adoption, HMI, XLSX/
naming/templates, and the private project-repo model. **Phase 6** (safety/LAD + distributed
ET200SP) is **proven at scale**: the private SR PPS project builds a whole fail-safe system
- 1 F-CPU + **16 ET200SP PROFINET stations (76 modules) + 16 F-LAD safety FBs** in one
project, **compiling 0/0** - via Openness. See [docs/ROADMAP.md](docs/ROADMAP.md) and
[docs/SAFETY-LAD-SPIKE.md](docs/SAFETY-LAD-SPIKE.md).

## One-time setup (required before anything can attach)

The calling user must be in the local Windows group **`Siemens TIA Openness`**, and —
critically — the token must be **refreshed by a log off/on**. On the reference machine
this is **done and validated** (`Validate-Full.ps1` passed: live attach + write path +
compile with 0 errors). On a fresh machine, run once (elevated) then log off/on:

```
.\scripts\Enable-OpennessAccess.ps1     # elevated; adds you to the group
# log off and back on (or reboot), then:
powershell -ExecutionPolicy Bypass -File .\scripts\Validate-Full.ps1
```

Why the log off/on is unavoidable: Windows bakes group membership into the logon token
at logon time. A `runas` shell *does* pick up the group, but it still can't (a) attach
to a TIA Portal owned by the old desktop token, nor (b) answer the first-use Openness
whitelist dialog from its window station — both were verified. Only a real re-login
puts the group into your interactive desktop token, which is what TIA Portal and
Openness clients run under.

Verify after re-login: `Get-TiaSession` lists sessions and `Connect-TiaPortal` attaches
without a security error; `Validate-Full.ps1` then exercises the whole write path.

## Quick start

```powershell
Import-Module .\src\TiaOpenness\TiaOpenness.psd1 -Force

Get-TiaSession                 # running Portals you can attach to
Connect-TiaPortal             # attach (read); or: Connect-TiaPortal -New (your own instance)
Get-TiaPlc                    # find CPUs

Get-TiaTag  | Select -First 20
Get-TiaBlock -Type FC

# writes — do these in a scratch project, not a human's live one:
New-TiaTag -TagTable IO -Name Start_PB -DataType Bool -Address '%I0.0'
Import-TiaScl -Path .\templates\Scale.scl
Invoke-TiaCompile
Save-TiaProject
```

## Tests

`tests\Test-Module.ps1` is an offline structural self-test (no TIA connection or
Openness group needed): module loads, manifest ⇄ exports agree, every cmdlet has
help, core cmdlets present, and `specs\demo.json` matches the generator schema. It
runs in CI (`.github/workflows/ci.yml`, `windows-latest`) on every push.

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Module.ps1
```

## Demos

- `scripts\Demo-ReadLiveProject.ps1` — read-only tour of whatever session is running.
- `scripts\Demo-ScratchWrites.ps1` — starts its own Portal, builds a throwaway project,
  creates tags + an SCL FC and FB, and compiles. Never touches your real project.

## Layout

```
src/TiaOpenness/         PowerShell module (the platform)
  Private/               assembly resolver, session state, YAML/XLSX readers, synthesizers
  Public/                exported cmdlets: Connect, Project, Hardware, Tags, Types,
                         Blocks, Organization, Hmi, Lifecycle, Build, Spec, Reverse,
                         Naming, Templates, ProjectRepo
  templates/             reusable SCL/UDT templates (MotorStarter, AnalogScale, ...)
  project-template/      skeleton for a new private project repo (see New-TiaProjectRepo)
scripts/                 setup, demo, and validation scripts
specs/                   declarative build specs (demo.json)
examples/example-project/ runnable end-to-end example (gitignored output)
docs/                    ROADMAP, SPECIFICATION, GUIDE, PROJECT-REPO-GUIDE, cheatsheet, ...
.claude/skills/          tia-openness, tia-hardware, tia-data, tia-programming, tia-hmi, tia-autocode
```

## Declarative generation

Describe a program as a **YAML manifest** referencing **CSV/XLSX** data (tags, UDTs, DBs,
rack modules, HMI tags) and **SCL** logic, then build it in one call:

```powershell
Test-TiaSpec              -Path .\project.yaml     # offline validation (no TIA)
Invoke-TiaBuildFromSpec   -Path .\project.yaml     # create + generate + compile
```

It creates the portal/project, adds the CPU + rack, generates UDTs, SCL blocks (files
**or** engine templates), data blocks, tags, and the HMI panel, then compiles. Names can
be linted (`Test-TiaNaming`) and workbooks read dependency-free (`Import-TiaXlsx`).

## Two-repo strategy: engine + private project repos

This repo is the reusable **public engine**. Each machine lives in its own **private
project repo** that consumes the engine as a pinned **git submodule** - so customer data
stays private and every machine builds against a known engine version. Scaffold one:

```powershell
New-TiaProjectRepo -Path E:\TIA_Portal\MyMachine -Name MyMachine
```

See **[docs/PROJECT-REPO-GUIDE.md](docs/PROJECT-REPO-GUIDE.md)** for the full worked
example (the `PPS_SR` repo: scaffold → submodule → validate in CI → build).

## This machine

TIA Portal V19/V20/V21 installed; Openness registered for **19.0** (classic, default)
and **21.0** (modular). The module is version-aware — `Connect-TiaPortal -Version 21.0`.
The user's real project (`E:\TIA_Portal\PPS_SR_\PPS_SR_.ap19`) is **read-only by
policy**; writes go to a scratch project.

## Documentation

- **[docs/ROADMAP.md](docs/ROADMAP.md)** — the plan and its status (Phases 0-5, all done): spec-driven project + HMI automation (spreadsheet → CSV/XLSX → generate).
- **[docs/SPECIFICATION.md](docs/SPECIFICATION.md)** — full feature spec, architecture, and 55-cmdlet reference.
- **[docs/GUIDE.md](docs/GUIDE.md)** — task-oriented usage guide (connect → tags → logic → compile → download → generate → authoring helpers).
- **[docs/AUTHORING.md](docs/AUTHORING.md)** — what to specify for a project and in which file (every manifest field + CSV column), plus how to create a new project from the template.
- **[docs/PROJECT-REPO-GUIDE.md](docs/PROJECT-REPO-GUIDE.md)** — the two-repo strategy and how a private project repo (e.g. `PPS_SR`) links this engine as a submodule.
- **[docs/SAFETY-LAD-SPIKE.md](docs/SAFETY-LAD-SPIKE.md)** — Phase 6 feasibility: proven LAD/F-LAD (FlgNet) generation, safety-block authoring, and ET200SP distributed-I/O creation via Openness.
- **[docs/framework.md](docs/framework.md)** — generator/architecture design.
- **[docs/openness-cheatsheet.md](docs/openness-cheatsheet.md)** — raw Openness idioms.
- **[docs/adding-a-device.md](docs/adding-a-device.md)** — CPU order numbers.
- Skills (`.claude/skills/`): `tia-openness` (connection), `tia-hardware` (devices/rack), `tia-data` (tags/UDTs/DBs), `tia-programming` (OB/FB/FC), `tia-hmi` (WinCC), `tia-autocode` (spec-driven build).
- Project instructions: [CLAUDE.md](CLAUDE.md).
