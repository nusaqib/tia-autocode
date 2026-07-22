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
| Module: connect / project / device / tags / blocks / compile | ✅ built, loads, 21 cmdlets exported |
| Session enumeration (`GetProcesses`) | ✅ validated against live V19 session |
| **Attach + read/write** | ⛔ **blocked on Windows group membership** (one-time admin step below) |

## One-time setup (required before anything can attach)

The calling user must be in the local Windows group **`Siemens TIA Openness`**.
It exists on this machine but currently has **no members**, so `Attach()` fails with
`EngineeringSecurityException`. Fix it **once**, elevated, then **log off and back on**:

```powershell
# Right-click Windows PowerShell -> Run as administrator, then:
cd e:\TIA_Portal\TIA_API
powershell -ExecutionPolicy Bypass -File .\scripts\Enable-OpennessAccess.ps1
# ...then LOG OFF and back on (or reboot) so your token includes the new group.
```

Verify: `Get-TiaSession` should list sessions, and `Connect-TiaPortal` should attach
without a security error.

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

## Demos

- `scripts\Demo-ReadLiveProject.ps1` — read-only tour of whatever session is running.
- `scripts\Demo-ScratchWrites.ps1` — starts its own Portal, builds a throwaway project,
  creates tags + an SCL FC and FB, and compiles. Never touches your real project.

## Layout

```
src/TiaOpenness/         PowerShell module (the platform)
  Private/               assembly resolver, session state, helpers
  Public/                exported cmdlets (Connect/Project/Tags/Blocks)
scripts/                 setup + demo scripts
templates/               sample SCL + SimaticML XML
docs/                    openness-cheatsheet.md, adding-a-device.md
.claude/skills/          the `tia-openness` skill (expertise for future sessions)
```

## This machine

TIA Portal V19/V20/V21 installed; Openness registered for **19.0** (classic, default)
and **21.0** (modular). The module is version-aware — `Connect-TiaPortal -Version 21.0`.
The user's real project (`E:\TIA_Portal\PPS_SR_\PPS_SR_.ap19`) is **read-only by
policy**; writes go to a scratch project.

See `docs/openness-cheatsheet.md` for raw Openness idioms and `.claude/skills/tia-openness/`
for the full skill.
