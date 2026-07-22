# Validate-Full.ps1
# Comprehensive, self-logging validation. Launch under a FRESH logon token (runas)
# so the client process carries the 'Siemens TIA Openness' group:
#
#   runas /user:%USERDOMAIN%\%USERNAME% "powershell -NoProfile -ExecutionPolicy Bypass -File e:\TIA_Portal\TIA_API\scripts\Validate-Full.ps1"
#
# It (1) reports token groups, (2) TRIES to attach to the running session and, if
# that works, reads the real CPU order number + a sample of tags/blocks (read-only,
# never writes to your project), then (3) starts its OWN headless Portal and drives
# the full WRITE path in a throwaway project: device -> tags -> SCL FC+FB -> compile.
param(
    [string]$WorkDir      = "$env:TEMP\TIA_API_Scratch",
    [string]$ProjectName  = 'ScratchDemo'
)
$ErrorActionPreference = 'Continue'
$log = 'e:\TIA_Portal\TIA_API\scripts\validate-full.log'
Start-Transcript -Path $log -Force | Out-Null
Import-Module 'e:\TIA_Portal\TIA_API\src\TiaOpenness\TiaOpenness.psd1' -Force

function Section($t){ Write-Host "`n==== $t ====" -ForegroundColor Cyan }

Section 'TOKEN GROUPS (expect Siemens TIA Openness)'
(whoami.exe /groups /fo csv | ConvertFrom-Csv | Where-Object { $_.'Group Name' -match 'Openness|TIA' } |
    Select-Object -ExpandProperty 'Group Name') -join "`n"

# ---------------------------------------------------------------- live attach test
$discoveredMlfb = $null
Section 'TRY ATTACH TO RUNNING SESSION (read-only)'
try {
    Get-TiaSession | Format-Table Id, Mode, ProjectPath -AutoSize | Out-String | Write-Host
    Connect-TiaPortal | Out-Null
    Write-Host "ATTACH OK" -ForegroundColor Green
    $plc = Get-TiaPlc | Select-Object -First 1
    if ($plc) {
        # Pull the CPU order number so we can mirror it in the scratch project.
        $di = $plc.PlcSoftware
        Write-Host ("Live PLC: {0}" -f $plc.Name)
        foreach ($d in (Get-TiaProject).Devices) {
            foreach ($item in $d.DeviceItems) {
                $tid = try { $item.GetAttribute('TypeIdentifier') } catch { $null }
                if ($tid -and $tid -match 'OrderNumber') { $discoveredMlfb = $tid; Write-Host "  Device MLFB: $tid" }
            }
        }
        Write-Host "Sample tags:";   Get-TiaTag  -Plc $di | Select-Object -First 8 | Format-Table Name,DataType,Address -AutoSize | Out-String | Write-Host
        Write-Host "Block counts:";  Get-TiaBlock -Plc $di | Group-Object Type | Format-Table Count,Name -AutoSize | Out-String | Write-Host
    }
    Disconnect-TiaPortal   # detach, leave their session open
} catch {
    Write-Host "ATTACH FAILED (expected until OS re-login): $($_.Exception.Message)" -ForegroundColor Yellow
}

# ------------------------------------------------------------- write path (our own)
Section 'WRITE PATH — dedicated headless Portal + scratch project'
$writeOk = $false
try {
    Connect-TiaPortal -New -WithUserInterface:$false | Out-Null
    Write-Host "Started own headless Portal OK" -ForegroundColor Green

    if (Test-Path "$WorkDir\$ProjectName") { Remove-Item "$WorkDir\$ProjectName" -Recurse -Force }
    New-TiaProject -Name $ProjectName -Path $WorkDir | Out-Null
    Write-Host "Created scratch project at $WorkDir\$ProjectName"

    # Candidate S7-1500 F-CPU order numbers, discovered one first. First that the
    # local catalog accepts wins (CreateWithItem throws on unknown MLFB).
    $candidates = @()
    if ($discoveredMlfb) { $candidates += $discoveredMlfb }
    $candidates += @(
        'OrderNumber:6ES7 512-1SN03-0AB0/V3.0'   # S7-1512SP F-1 PN (ET200SP)
        'OrderNumber:6ES7 512-1SM03-0AB0/V3.0'   # S7-1512SP F-1 PN variant
        'OrderNumber:6ES7 511-1FK02-0AB0/V2.9'   # S7-1511F-1 PN
        'OrderNumber:6ES7 513-1FL02-0AB0/V2.9'   # S7-1513F-1 PN
        'OrderNumber:6ES7 515-2FM02-0AB0/V2.9'   # S7-1515F-2 PN
        'OrderNumber:6ES7 511-1AK02-0AB0/V2.9'   # S7-1511-1 PN (standard fallback)
    )
    $added = $null
    foreach ($mlfb in $candidates) {
        try {
            New-TiaDevice -TypeIdentifier $mlfb -Name 'PLC_1' | Out-Null
            $added = $mlfb; Write-Host "Added CPU: $mlfb" -ForegroundColor Green; break
        } catch {
            Write-Host "  catalog rejected $mlfb" -ForegroundColor DarkGray
        }
    }
    if (-not $added) { throw "No candidate CPU order number is in this catalog. Provide the exact S7-1512F MLFB." }

    $sw = (Get-TiaPlc | Select-Object -First 1).PlcSoftware

    Write-Host "Creating tags..."
    New-TiaTag -Plc $sw -TagTable 'IO' -Name 'Start_PB'  -DataType 'Bool' -Address '%I0.0' | Out-Null
    New-TiaTag -Plc $sw -TagTable 'IO' -Name 'Stop_PB'   -DataType 'Bool' -Address '%I0.1' | Out-Null
    New-TiaTag -Plc $sw -TagTable 'IO' -Name 'Motor_Run' -DataType 'Bool' -Address '%Q0.0' | Out-Null
    Get-TiaTag -Plc $sw -TagTable 'IO' | Format-Table Name,DataType,Address -AutoSize | Out-String | Write-Host

    Write-Host "Importing SCL FC 'Scale' and FB 'MotorStarter'..."
    Import-TiaScl -Plc $sw -Path 'e:\TIA_Portal\TIA_API\templates\Scale.scl' | Out-Null
    Import-TiaScl -Plc $sw -Scl @'
FUNCTION_BLOCK "MotorStarter"
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT
    Start : Bool;
    Stop  : Bool;
END_VAR
VAR_OUTPUT
    Running : Bool;
END_VAR
BEGIN
    IF #Start THEN #Running := TRUE; END_IF;
    IF #Stop  THEN #Running := FALSE; END_IF;
END_FUNCTION_BLOCK
'@ | Out-Null
    Get-TiaBlock -Plc $sw | Format-Table Name,Type,Number,Language -AutoSize | Out-String | Write-Host

    Write-Host "Compiling..."
    $c = Invoke-TiaCompile -Plc $sw
    Write-Host ("Compile State={0}  Errors={1}  Warnings={2}" -f $c.State, $c.Errors, $c.Warnings)
    $c.Messages | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" }

    Save-TiaProject
    $writeOk = ($c.Errors -eq 0)
    Disconnect-TiaPortal -Close   # dispose the instance WE started
} catch {
    Write-Host "WRITE PATH FAILED: $($_.Exception.Message)" -ForegroundColor Red
    try { Disconnect-TiaPortal -Close } catch {}
}

Section 'SUMMARY'
Write-Host ("Write-path validation: {0}" -f ($(if($writeOk){'PASSED'}else{'INCOMPLETE — see log'})))
Stop-Transcript | Out-Null
Write-Host "`nLog: $log"
Start-Sleep -Seconds 3
