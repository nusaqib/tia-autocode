# Validate-Openness.ps1
# Runs the read-only smoke test and tees all output to a log file so results can be
# reviewed after the (possibly transient) window closes. Intended to be launched
# under a FRESH logon token (e.g. via runas) when a full log off/on isn't possible.
#
#   runas /user:%USERDOMAIN%\%USERNAME% "powershell -NoProfile -ExecutionPolicy Bypass -File e:\TIA_Portal\TIA_API\scripts\Validate-Openness.ps1"
#
$ErrorActionPreference = 'Continue'
$log = 'e:\TIA_Portal\TIA_API\scripts\validate-openness.log'
Start-Transcript -Path $log -Force | Out-Null

Write-Host "Token groups (expect 'Siemens TIA Openness' here):"
(whoami.exe /groups /fo csv | ConvertFrom-Csv | Where-Object { $_.'Group Name' -match 'Openness|TIA' } |
    Select-Object -ExpandProperty 'Group Name') -join "`n"

try {
    & "$PSScriptRoot\Demo-ReadLiveProject.ps1"
    Write-Host "`nRESULT: READ VALIDATION PASSED" -ForegroundColor Green
} catch {
    Write-Host "`nRESULT: FAILED -> $($_.Exception.Message)" -ForegroundColor Red
}

Stop-Transcript | Out-Null
Write-Host "`nLog written to $log"
Start-Sleep -Seconds 2
