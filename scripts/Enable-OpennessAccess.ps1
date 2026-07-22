# Enable-OpennessAccess.ps1
# Adds a user to the local "Siemens TIA Openness" group, which TIA Openness
# requires before TiaPortal.Attach() / project access will work.
#
# MUST be run elevated (Administrator). After it succeeds the target user must
# LOG OFF and back ON (or reboot) so their access token picks up the new group.
#
#   Right-click PowerShell -> Run as administrator, then:
#   powershell -ExecutionPolicy Bypass -File .\Enable-OpennessAccess.ps1
#
param(
    [string]$User = "$env:USERDOMAIN\$env:USERNAME"
)
$ErrorActionPreference = 'Stop'

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
}

$group = 'Siemens TIA Openness'
Get-LocalGroup $group | Out-Null   # throws if the group is missing

$already = Get-LocalGroupMember $group -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq $User -or $_.Name -ieq "$env:COMPUTERNAME\$($User.Split('\')[-1])" }

if ($already) {
    Write-Host "'$User' is already a member of '$group'." -ForegroundColor Green
} else {
    Add-LocalGroupMember -Group $group -Member $User
    Write-Host "Added '$User' to '$group'." -ForegroundColor Green
}

Write-Host ""
Write-Host "IMPORTANT: log off and back on (or reboot) before Openness Attach() will work." -ForegroundColor Yellow
Get-LocalGroupMember $group | Select-Object Name, PrincipalSource
