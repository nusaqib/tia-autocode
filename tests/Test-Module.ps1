# Test-Module.ps1
# Offline structural self-test - runs WITHOUT a TIA connection or the Openness group.
# Validates that the module loads, every exported function has comment-based help and
# resolves, the manifest and loader agree, and the demo spec matches the schema the
# generator expects. Exits non-zero on failure (CI-friendly).
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $([Environment]::OSVersion.VersionString)"
Write-Host "Repo root: $root`n"
function Check($name, [scriptblock]$test) {
    try {
        $r = & $test
        if ($r -eq $false) {
            Write-Host "[FAIL] $name" -ForegroundColor Red
            Write-Host "::error::CHECK FAILED: $name"          # GitHub annotation (readable via API)
            $script:fail++
        } else { Write-Host "[ ok ] $name" -ForegroundColor Green }
    } catch {
        Write-Host "[FAIL] $name -> $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "::error::CHECK ERROR: $name -> $($_.Exception.Message)"
        $script:fail++
    }
}

try {
    Import-Module (Join-Path $root 'src\TiaOpenness\TiaOpenness.psd1') -Force -ErrorAction Stop
} catch {
    Write-Host "::error::Import-Module failed: $($_.Exception.Message)"
    Write-Host "IMPORT FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
$cmds = @(Get-Command -Module TiaOpenness)
Write-Host "Imported module; exported command count = $($cmds.Count)"

Check "module exports >= 30 commands (got $($cmds.Count))" { $cmds.Count -ge 30 }

# Manifest FunctionsToExport must equal what's actually exported.
$manifest = Import-PowerShellDataFile (Join-Path $root 'src\TiaOpenness\TiaOpenness.psd1')
Check "manifest FunctionsToExport matches exported set" {
    $declared = $manifest.FunctionsToExport | Sort-Object
    $actual   = $cmds.Name | Sort-Object
    -not (Compare-Object $declared $actual)
}

# Every public function should carry comment-based help (documentation discipline).
# Inspect the function definition text directly - deterministic and independent of
# the Get-Help subsystem / help-file state on the host.
foreach ($c in $cmds) {
    Check "help: $($c.Name) has a .SYNOPSIS" {
        $def = (Get-Command $c.Name -ErrorAction Stop).Definition
        $def -match '(?im)^\s*\.SYNOPSIS\b'
    }
}

# Core cmdlets must exist by name (guards against accidental removal/rename).
$core = 'Connect-TiaPortal','Get-TiaPlc','New-TiaTag','Import-TiaScl','Invoke-TiaCompile',
        'New-TiaDataBlock','Get-TiaHmi','Invoke-TiaBuildFromSpec','Export-TiaProgram','Test-TiaSpec',
        'Add-TiaModule','Get-TiaModule','Get-TiaDeviceList','Export-TiaToSpec'
foreach ($n in $core) { Check "core cmdlet present: $n" { [bool](Get-Command $n -ErrorAction SilentlyContinue) } }

# Phase 1: CSV -> SCL synthesizers (Private; call in module scope).
$mod = Get-Module TiaOpenness
Check "UDT synthesizer emits TYPE/END_TYPE with array + UDT ref" {
    $rows = Import-Csv (Join-Path $root 'examples\example-project\data\PLC_1.udts.csv')
    $scl = & $mod { param($r) ConvertTo-TiaUdtScl $r } $rows
    $scl -match 'TYPE "MotorData"' -and $scl -match 'END_TYPE' -and $scl -match 'Array\[0\.\.9\] of Real'
}
Check "DB synthesizer emits instance DB body" {
    $b = (Import-Csv (Join-Path $root 'examples\example-project\data\PLC_1.dbs.blocks.csv') | Where-Object DBName -eq 'Motor1_DB')
    $scl = & $mod { param($blk) ConvertTo-TiaDbScl $blk $null } $b
    $scl -match 'DATA_BLOCK "Motor1_DB"' -and $scl -match '"MotorStarter"' -and $scl -match 'END_DATA_BLOCK'
}
Check "DB synthesizer emits global VAR block with UDT member" {
    $b = (Import-Csv (Join-Path $root 'examples\example-project\data\PLC_1.dbs.blocks.csv') | Where-Object DBName -eq 'Settings')
    $m = @(Import-Csv (Join-Path $root 'examples\example-project\data\PLC_1.dbs.members.csv') | Where-Object DBName -eq 'Settings')
    $scl = & $mod { param($blk,$mem) ConvertTo-TiaDbScl $blk $mem } $b $m
    $scl -match 'VAR' -and $scl -match 'Motor1 : "MotorData"' -and $scl -match 'END_VAR'
}

# Phase 0: offline spec validation (no TIA needed).
Check "example project spec validates clean" {
    $r = Test-TiaSpec -Path (Join-Path $root 'examples\example-project\project.yaml')
    $r.Ok -and $r.Errors.Count -eq 0
}
Check "broken fixture spec is rejected (incl. module errors)" {
    $r = Test-TiaSpec -Path (Join-Path $root 'tests\fixtures\broken-project\project.yaml')
    if ($r.Ok) { Write-Host "    expected failure but got Ok" -ForegroundColor Red }
    $modErr = @($r.Errors | Where-Object { $_ -match 'Modules\[' }).Count -ge 1
    (-not $r.Ok) -and $r.Errors.Count -ge 5 -and $modErr
}

# Phase 3: HMI spec validation (offline).
Check "HMI spec fixture validates clean" {
    $r = Test-TiaSpec -Path (Join-Path $root 'tests\fixtures\hmi-spec\project.yaml')
    if (-not $r.Ok) { Write-Host "    errors: $($r.Errors -join '; ')" -ForegroundColor Red }
    $r.Ok -and $r.Errors.Count -eq 0
}
Check "broken fixture flags HMI errors (dup tag, missing DataType, missing screen)" {
    $r = Test-TiaSpec -Path (Join-Path $root 'tests\fixtures\broken-project\project.yaml')
    $dup    = @($r.Errors | Where-Object { $_ -match 'HMITags.*duplicate' }).Count -ge 1
    $noType = @($r.Errors | Where-Object { $_ -match 'HMITags.*DataType is required' }).Count -ge 1
    $noScr  = @($r.Errors | Where-Object { $_ -match 'HMI.*screen XML not found' }).Count -ge 1
    $dup -and $noType -and $noScr
}

# Demo spec parses and has the shape the generator reads.
Check "specs/demo.json parses and has plcs[0].tagTables[0].tags" {
    $s = Get-Content (Join-Path $root 'specs\demo.json') -Raw | ConvertFrom-Json
    $s.plcs -and $s.plcs[0].tagTables[0].tags.Count -ge 1 -and $s.project.name
}

# Source must be ASCII-only: Windows PowerShell 5.1 reads BOM-less .ps1 as the ANSI
# code page, so a stray em-dash/smart-quote breaks parsing (this exact bug failed CI).
Check "PowerShell sources are ASCII-only" {
    $offenders = @()
    Get-ChildItem $root -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object {
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines($_.FullName)) {
            $n++
            if ($line -match '[^\x00-\x7F]') {
                $offenders += "$($_.Name):$n"
            }
        }
    }
    if ($offenders.Count) { Write-Host "    non-ASCII at: $($offenders -join ', ')" -ForegroundColor Red }
    $offenders.Count -eq 0
}

# Version detection works offline (reads registry only, no Attach). Skipped on
# machines without TIA installed (e.g. CI runners) so the rest still validates.
if (Test-Path 'HKLM:\SOFTWARE\Siemens\Automation\Openness') {
    Check "Get-TiaInstalledVersion returns at least one version" {
        (@(Get-TiaInstalledVersion)).Count -ge 1
    }
} else {
    Write-Host "[skip] Get-TiaInstalledVersion (no TIA Openness on this machine)" -ForegroundColor Yellow
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
