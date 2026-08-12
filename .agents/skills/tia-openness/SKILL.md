---
name: tia-openness
description: Connect to a Siemens TIA Portal session via Openness and program PLCs — enumerate/attach sessions, open projects, and read or create PLC tags, tag tables, and logic blocks (FC/FB/OB) including SCL routines, then compile. Use whenever the task involves TIA Portal, Openness, S7-1200/1500/300/400 PLCs, SCL/LAD/FBD/STL, PLC tags, or the Siemens.Engineering API on this machine.
---

# TIA Portal Openness automation

This repo (`e:\TIA_Portal\TIA_API`) drives Siemens TIA Portal through its Openness
.NET API using a PowerShell 5.1 module, `TiaOpenness`. Prefer the module's cmdlets;
drop to raw `Siemens.Engineering` types only for things the module doesn't wrap yet.

## Preconditions (verify first when Attach fails)

1. **Group membership** — the calling user MUST be in the local Windows group
   `Siemens TIA Openness`. `TiaPortal.GetProcesses()` works without it, but
   `Attach()` and all project access throw `EngineeringSecurityException` without it.
   Fix (elevated) then **log off/on**:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Enable-OpennessAccess.ps1
   ```
2. **PowerShell edition** — must be Windows PowerShell 5.1 (Desktop CLR / .NET FW 4.8).
   Openness is .NET Framework; PowerShell 7 (Core) will not load it here.
3. **Version** — this machine has Openness `19.0` (classic API, default) and `21.0`
   (modular API). The module defaults to classic V19. Force with
   `Connect-TiaPortal -Version 21.0`. You cannot load two versions in one process.

## Environment facts (this machine)

- Installs: `C:\Program Files\Siemens\Automation\Portal V19|V20|V21`.
- V19 entry DLL: `...\Portal V19\PublicAPI\V19\Siemens.Engineering.dll` (PK `d29ec89bac048f84`).
- V21 entry DLL: `...\Portal V21\PublicAPI\V21\net48\Siemens.Engineering.Base.dll` (PK `29bfe5fdf4ba5d3b`).
- No .NET SDK — build compiled tools with `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` / MSBuild, target net48.
- The user's real project is `E:\TIA_Portal\PPS_SR_\PPS_SR_.ap19` — **never modify it without explicit consent**; write to a scratch project.

## Core workflow

```powershell
Import-Module .\src\TiaOpenness\TiaOpenness.psd1 -Force

Get-TiaSession                       # list attachable running Portals
Connect-TiaPortal                    # attach to the running one (or -New for a fresh instance)
Get-TiaPlc                           # find CPUs (returns .PlcSoftware handle)

# Read
Get-TiaTagTable
Get-TiaTag  | Where DataType -eq 'Bool'
Get-TiaBlock -Type FC

# Write (do this against a scratch project you created, not a human's live one)
New-TiaTag -TagTable IO -Name Start_PB -DataType Bool -Address '%I0.0'
Import-TiaScl -Scl '<FUNCTION ... END_FUNCTION>'    # authors an FC/FB/OB from text
Invoke-TiaCompile                                   # returns State/Errors/Warnings/Messages
Save-TiaProject
```

To build a project from nothing: `Connect-TiaPortal -New` → `New-TiaProject` →
`New-TiaDevice -TypeIdentifier 'OrderNumber:6ES7 511-1AK02-0AB0/V2.9' -Name PLC_1`
→ tags/blocks. See `docs/adding-a-device.md` for catalog identifiers.

## Authoring logic — two paths

- **SCL text → blocks (default, easiest):** `Import-TiaScl` writes the SCL to a temp
  file, registers it as an external source, and calls `GenerateBlocksFromSource()`.
  Best for FCs/FBs/OBs written as code. One source can define several blocks.
- **SimaticML XML → blocks (full fidelity):** `Import-TiaBlockXml` for LAD/FBD/STL,
  networks, interfaces, comments, and exact addressing. Learn the schema by round-
  tripping: `Export-TiaBlock -Name <existing> -Path b.xml`, edit, re-import. See
  `templates/` for a minimal FC example.

## Safety rules

- Attach to a human's session read-only; for writes start your OWN instance
  (`Connect-TiaPortal -New`) or work in a scratch project.
- Only `Disconnect-TiaPortal -Close` an instance you started (`-New`). Never dispose
  a session a person is using.
- Always `Save-TiaProject` before closing; check `Invoke-TiaCompile` errors before claiming success.

## Cmdlet map

| Area | Cmdlets |
|------|---------|
| Setup/diag | `Get-TiaInstalledVersion`, `Get-TiaOpennessState` |
| Session | `Get-TiaSession`, `Connect-TiaPortal`, `Disconnect-TiaPortal` |
| Project | `New-TiaProject`, `Open-TiaProject`, `Get-TiaProject`, `Save-TiaProject`, `Close-TiaProject` |
| Hardware | `New-TiaDevice`, `Get-TiaPlc` |
| Tags | `Get-TiaTagTable`, `New-TiaTagTable`, `Get-TiaTag`, `New-TiaTag` |
| Data types / DBs | `Get-TiaType`, `New-TiaType`, `New-TiaDataBlock` |
| Blocks | `Get-TiaBlock`, `Import-TiaScl`, `Import-TiaBlockXml`, `Export-TiaBlock`, `New-TiaOb`, `Invoke-TiaCompile` |
| Block folders | `New-TiaBlockGroup`, `Get-TiaBlockGroup`, `Remove-TiaBlock` |
| HMI (see tia-hmi skill) | `Get-TiaHmi`, `Show-TiaHmiApi`, `Get-TiaScreen`, `Export-TiaScreen`, `Import-TiaScreen` |
| Lifecycle | `Export-TiaProgram`, `Get-TiaOnlineState`, `Invoke-TiaDownload` |
| Generator | `Invoke-TiaBuildFromSpec` (declarative JSON → full program) |

Full API reference and raw-Openness idioms: `docs/openness-cheatsheet.md`.
Framework/generator design: `docs/framework.md`. HMI: the `tia-hmi` skill.

## Declarative build (the automatic-coding layer)

Describe a program as JSON and generate it: `Invoke-TiaBuildFromSpec -Path .\specs\demo.json`.
Sections: `portal`, `project`, `plcs[]` (device, tagTables, types, blocks, dataBlocks,
compile), `hmis[]` (screen XML import), `save`. Per-item errors are collected, not fatal.
