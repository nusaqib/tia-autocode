# High-level entry points over Invoke-TiaBuildFromSheet: run the whole phase pipeline,
# and clear the generated output so the next run starts from nothing.
#
# These exist because the eight phases are ORDERED and each one's output is the next one's
# input - typing them by hand invites building Certified logic against a stale F-DB.

# The pipeline order. Project creates the project file; every later phase opens it again.
$script:TiaSheetPhaseOrder = @('Project','Hardware','UDTs','DB','Tags','IOMap','Certified','Interlocks')

function Invoke-TiaSheetPipeline {
    <#
    .SYNOPSIS
        Run the design-sheet build phases in order, stopping at the first failure.
    .DESCRIPTION
        Equivalent to calling Invoke-TiaBuildFromSheet once per phase, in the order the
        phases depend on each other, with one summary at the end.

        It STOPS at the first failing phase by default. The phases are a chain - Tags reads
        the address map the Hardware phase wrote, Certified reads the F-DB the DB phase
        created - so continuing past a failure builds safety logic on top of a known-bad
        foundation. -ContinueOnError is for diagnosing how far the design gets, not for
        producing a program.
    .PARAMETER Path
        Design CSV snapshot folder (default: .\design\csv).
    .PARAMETER Phase
        Subset of phases to run, in pipeline order regardless of how they are listed.
        Default: all eight.
    .PARAMETER From
        Start at this phase and run the rest (e.g. -From DB after fixing a UDT).
    .PARAMETER Clean
        Delete the generated project first, so the run starts from nothing.
    .PARAMETER ContinueOnError
        Keep going after a phase fails. The result is NOT a releasable program.
    .EXAMPLE
        Invoke-TiaSheetPipeline -Path .\design\csv -Save
    .EXAMPLE
        Invoke-TiaSheetPipeline -Clean -Save
    .EXAMPLE
        Invoke-TiaSheetPipeline -From DB -Save
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '.\design\csv',
        [string]$ProjectPath,
        [ValidateSet('Project','Hardware','UDTs','DB','Tags','IOMap','Certified','Interlocks')][string[]]$Phase,
        [ValidateSet('Project','Hardware','UDTs','DB','Tags','IOMap','Certified','Interlocks')][string]$From,
        [switch]$Clean,
        [switch]$Force,
        [switch]$RequireVerified,
        [switch]$ContinueOnError,
        [switch]$Save
    )
    $ErrorActionPreference = 'Stop'
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    $run = @($script:TiaSheetPhaseOrder)
    if ($Phase) { $run = @($script:TiaSheetPhaseOrder | Where-Object { $Phase -contains $_ }) }
    if ($From) {
        $i = [array]::IndexOf($script:TiaSheetPhaseOrder, $From)
        $run = @($run | Where-Object { [array]::IndexOf($script:TiaSheetPhaseOrder, $_) -ge $i })
    }
    if (-not $run.Count) { throw "No phases selected." }

    if ($Clean) { Clear-TiaSheetBuild -Path $Path -ProjectPath $ProjectPath -Confirm:$false | Out-Null }

    Write-Host ("pipeline: {0}" -f ($run -join ' -> ')) -ForegroundColor Cyan
    $results = @(); $failed = $null
    foreach ($p in $run) {
        Write-Host ""
        Write-Host ("=== {0} ===" -f $p) -ForegroundColor Cyan
        $ok = $true; $err = $null
        try {
            $r = Invoke-TiaBuildFromSheet -Path $Path -ProjectPath $ProjectPath -Phase $p `
                    -Force:$Force -Save:$Save -RequireVerified:$RequireVerified
        } catch {
            $ok = $false; $err = $_.Exception.Message; $r = $null
        }
        # A phase can also report failure in-band (compile errors) without throwing.
        if ($ok -and $r -and ($r.PSObject.Properties.Name -contains 'Ok') -and -not $r.Ok) {
            $ok = $false
            $err = $(if ($r.PSObject.Properties.Name -contains 'Error' -and $r.Error) { [string]$r.Error } else { 'phase reported Ok=False' })
        }
        $results += [pscustomobject]@{ Phase = $p; Ok = $ok; Error = $err; Result = $r }
        if (-not $ok) {
            Write-Host ("  {0} FAILED: {1}" -f $p, $err) -ForegroundColor Red
            if (-not $failed) { $failed = $p }
            if (-not $ContinueOnError) { break }
        }
    }

    Write-Host ""
    Write-Host "=== pipeline summary ===" -ForegroundColor Cyan
    foreach ($x in $results) {
        $mark = $(if ($x.Ok) { 'ok  ' } else { 'FAIL' })
        $col  = $(if ($x.Ok) { 'Green' } else { 'Red' })
        Write-Host ("  {0,-10} {1}" -f $x.Phase, $mark) -ForegroundColor $col
    }
    $skipped = @($run | Where-Object { $_ -notin @($results | ForEach-Object { $_.Phase }) })
    if ($skipped.Count) { Write-Host ("  not run: {0}" -f ($skipped -join ', ')) -ForegroundColor DarkGray }

    [pscustomobject]@{
        Ok      = (-not $failed)
        Phases  = $results
        Failed  = $failed
        Skipped = $skipped
    }
}

function Clear-TiaSheetBuild {
    <#
    .SYNOPSIS
        Delete the generated TIA project and build artefacts for a design snapshot.
    .DESCRIPTION
        Removes the project folder named by 10_Project's ProjectPath, the generated XML
        staging folder, and the generated reports - everything the build produces and
        nothing it consumes. The design workbook and design/csv are never touched.

        REFUSES to delete a folder outside the design repo's generated-output tree unless
        -Force is given. A typo in ProjectPath must not be able to delete somebody's live
        project, and this platform's rule is that human projects are read-only.
    .PARAMETER Path
        Design CSV snapshot folder (default: .\design\csv).
    .PARAMETER ProjectPath
        Project folder to delete. Defaults to 10_Project's ProjectPath key.
    .PARAMETER KeepReports
        Leave reports/ alone (they are the record of the last build).
    .PARAMETER Force
        Allow deleting a project folder outside the repo's generated-output tree.
    .EXAMPLE
        Clear-TiaSheetBuild -Path .\design\csv
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$Path = '.\design\csv',
        [string]$ProjectPath,
        [switch]$KeepReports,
        [switch]$Force
    )
    $ErrorActionPreference = 'Stop'
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path $Path)) { throw "No design snapshot at $Path" }

    $repoRoot = Split-Path -Parent (Split-Path -Parent $Path)
    $model = Read-TiaSheetModel -Path $Path
    $proj  = $model.Project
    $ProjectPath = Resolve-TiaProjectPath -ProjectPath $ProjectPath -Project $proj -RepoRoot $repoRoot

    # Guard: only ever delete inside the repo's generated-output tree.
    $outRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '_out'))
    $inOut = $ProjectPath.TrimEnd('\').ToLowerInvariant().StartsWith($outRoot.TrimEnd('\').ToLowerInvariant() + '\')
    if (-not $inOut -and -not $Force) {
        throw ("Refusing to delete '$ProjectPath' - it is outside the generated-output tree " +
               "($outRoot). Live projects are read-only on this platform; pass -Force only if " +
               "you are certain this folder is disposable.")
    }

    $targets = @()
    if (Test-Path $ProjectPath) { $targets += $ProjectPath }
    $xmlDir = Join-Path $repoRoot '_out\xml'
    if (Test-Path $xmlDir) { $targets += $xmlDir }
    if (-not $KeepReports) {
        foreach ($f in @('90_AddressMap.csv','91_TagList.csv','92_Coverage.csv','93_Certified.csv')) {
            $rp = Join-Path $repoRoot "reports\$f"
            if (Test-Path $rp) { $targets += $rp }
        }
    }

    $removed = @()
    foreach ($t in $targets) {
        if ($PSCmdlet.ShouldProcess($t, 'Remove')) {
            try {
                Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop
                $removed += $t
                Write-Host ("  removed {0}" -f $t)
            } catch {
                # A TIA project still open in the Portal holds its files - say so plainly
                # rather than reporting a clean wipe that did not happen.
                throw "Could not remove '$t': $($_.Exception.Message) (is the project open in TIA Portal?)"
            }
        }
    }
    if (-not $targets.Count) { Write-Host "  nothing to remove" -ForegroundColor DarkGray }

    [pscustomobject]@{ Ok = $true; ProjectPath = $ProjectPath; Removed = $removed }
}
