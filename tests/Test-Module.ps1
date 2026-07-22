# Test-Module.ps1
# Offline structural self-test — runs WITHOUT a TIA connection or the Openness group.
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
# Inspect the function definition text directly — deterministic and independent of
# the Get-Help subsystem / help-file state on the host.
foreach ($c in $cmds) {
    Check "help: $($c.Name) has a .SYNOPSIS" {
        $def = (Get-Command $c.Name -ErrorAction Stop).Definition
        $def -match '(?im)^\s*\.SYNOPSIS\b'
    }
}

# Core cmdlets must exist by name (guards against accidental removal/rename).
$core = 'Connect-TiaPortal','Get-TiaPlc','New-TiaTag','Import-TiaScl','Invoke-TiaCompile',
        'New-TiaDataBlock','Get-TiaHmi','Invoke-TiaBuildFromSpec','Export-TiaProgram'
foreach ($n in $core) { Check "core cmdlet present: $n" { [bool](Get-Command $n -ErrorAction SilentlyContinue) } }

# Demo spec parses and has the shape the generator reads.
Check "specs/demo.json parses and has plcs[0].tagTables[0].tags" {
    $s = Get-Content (Join-Path $root 'specs\demo.json') -Raw | ConvertFrom-Json
    $s.plcs -and $s.plcs[0].tagTables[0].tags.Count -ge 1 -and $s.project.name
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
