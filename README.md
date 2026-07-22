# TIA_API — Siemens TIA Portal automatic coding platform

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
| Module: connect / project / device / tags / types / DBs / blocks / HMI / compile / export / download | ✅ built, loads, **37 cmdlets** exported |
| Declarative generator (`Invoke-TiaBuildFromSpec`) | ✅ built |
| Session enumeration (`GetProcesses`) | ✅ validated against live V19 session |
| Group membership (`Siemens TIA Openness`) | ✅ user added |
| **Attach + read/write** | ⏳ needs one **log off/on** to activate the group in the desktop token (see below) |

## One-time setup (required before anything can attach)

The calling user must be in the local Windows group **`Siemens TIA Openness`**, and —
critically — the token must be **refreshed by a log off/on**. Adding to the group is
done (via `scripts\Enable-OpennessAccess.ps1`, elevated). What remains:

```
Log off and back on (or reboot), then:
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
  Private/               assembly resolver, session state, helpers
  Public/                exported cmdlets: Connect, Project, Tags, Types,
                         Blocks, Organization, Hmi, Lifecycle, Build
scripts/                 setup, demo, and validation scripts
specs/                   declarative build specs (demo.json)
templates/               sample SCL + SimaticML XML
docs/                    openness-cheatsheet.md, framework.md, adding-a-device.md
.claude/skills/          tia-openness + tia-hmi skills (expertise for future sessions)
```

## Declarative generation

Describe a program as JSON and build it in one call:

```powershell
Invoke-TiaBuildFromSpec -Path .\specs\demo.json
```

It creates the portal/project, adds the CPU, and generates tag tables, UDTs, SCL
blocks, data blocks, and HMI screens, then compiles. See `docs/framework.md`.

## This machine

TIA Portal V19/V20/V21 installed; Openness registered for **19.0** (classic, default)
and **21.0** (modular). The module is version-aware — `Connect-TiaPortal -Version 21.0`.
The user's real project (`E:\TIA_Portal\PPS_SR_\PPS_SR_.ap19`) is **read-only by
policy**; writes go to a scratch project.

See `docs/openness-cheatsheet.md` for raw Openness idioms and `.claude/skills/tia-openness/`
for the full skill.
