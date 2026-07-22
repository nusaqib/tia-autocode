# Demo-ReadLiveProject.ps1
# Read-only smoke test against whatever TIA session is currently running.
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\src\TiaOpenness\TiaOpenness.psd1" -Force

Write-Host "== Installed Openness versions ==" -ForegroundColor Cyan
Get-TiaInstalledVersion | Format-Table Version, IsModular, PublicKeyToken -AutoSize

Write-Host "== Running sessions ==" -ForegroundColor Cyan
Get-TiaSession | Format-Table Id, Mode, ProjectPath -AutoSize

Write-Host "== Attaching ==" -ForegroundColor Cyan
$c = Connect-TiaPortal
"Version=$($c.Version)  OpenProjects=$($c.OpenProjects -join ', ')"

Write-Host "== PLCs ==" -ForegroundColor Cyan
$plcs = Get-TiaPlc
$plcs | Format-Table Name, Device, DeviceItem -AutoSize

if ($plcs) {
    $plc = $plcs[0].PlcSoftware
    Write-Host "== Tag tables (first PLC) ==" -ForegroundColor Cyan
    Get-TiaTagTable -Plc $plc | Format-Table Name, Group, TagCount -AutoSize

    Write-Host "== First 15 tags ==" -ForegroundColor Cyan
    Get-TiaTag -Plc $plc | Select-Object -First 15 | Format-Table Name, DataType, Address, Table -AutoSize

    Write-Host "== Blocks (first 20) ==" -ForegroundColor Cyan
    Get-TiaBlock -Plc $plc | Select-Object -First 20 | Format-Table Name, Type, Number, Language -AutoSize

    Write-Host "== Block counts by type ==" -ForegroundColor Cyan
    Get-TiaBlock -Plc $plc | Group-Object Type | Format-Table Count, Name -AutoSize
}

Write-Host "== Detaching (leaving session open) ==" -ForegroundColor Cyan
Disconnect-TiaPortal
Write-Host "Done." -ForegroundColor Green
