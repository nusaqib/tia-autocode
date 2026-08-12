# Build a TIA project from a design sheet snapshot.
#
# The sheet IS the project definition: everything this cmdlet needs comes from design/csv,
# with no per-project scripts and no constants hidden in code. Schema: docs/DESIGN-SHEET.md.

function Invoke-TiaBuildFromSheet {
    <#
    .SYNOPSIS
        Build a TIA Portal project from a design-sheet CSV snapshot.
    .DESCRIPTION
        Phase 'Hardware' creates the project, the CPU, one station per zone, plugs every
        module at its designed slot, wires one PROFINET subnet + IO system, compiles, and
        reports the assigned I/O addresses.

        Validation gate, deliberately asymmetric:
          Hardware  runs Test-TiaDesignSheet and needs -Force to proceed past unrelated
                    design errors, but ALWAYS refuses if the hardware rows themselves are
                    incomplete. Racks and modules are inert - a wrong one does not trip.
          Logic     refuses outright unless validation is clean. Certified safety logic is
                    never generated from a design that does not validate, and -Force does
                    not override that.
    .PARAMETER Path
        Design CSV snapshot folder (default: .\design\csv).
    .PARAMETER ProjectPath
        Output folder for the TIA project. Defaults to 10_Project's ProjectPath key.
    .PARAMETER Phase
        Hardware (default), Types, Data, Tags, IOMap, Certified or Safety. Only Hardware is
        implemented; the others have a defined input/output contract in the project's
        docs/BUILD.md and throw until built.
    .PARAMETER Force
        Proceed past design-validation errors that do not affect the hardware rows.
    .PARAMETER Save
        Save the project when the build finishes.
    .PARAMETER ReportPath
        Where to write the address map (default: <repo>\reports\90_AddressMap.csv).
    .EXAMPLE
        Invoke-TiaBuildFromSheet -Path .\design\csv -Phase Hardware -Save
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '.\design\csv',
        [string]$ProjectPath,
        [ValidateSet('Hardware','Types','Data','Tags','IOMap','Certified','Safety')][string]$Phase = 'Hardware',
        [switch]$Force,
        [switch]$Save,
        [string]$ReportPath
    )
    $ErrorActionPreference = 'Stop'
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path $Path)) { throw "No design snapshot at $Path" }

    if ($Phase -ne 'Hardware') {
        throw ("Phase '$Phase' is not implemented yet. Its input/output contract is defined in " +
               "the project's docs/BUILD.md; only 'Hardware' is built today.")
    }

    # --- design gate ------------------------------------------------------------------
    # Asymmetric on purpose: racks are inert, so an unrelated design error can be forced
    # past. Certified safety logic is the trip path and gets no such escape hatch.
    $val = Test-TiaDesignSheet -Path $Path
    Write-Host "design: $($val.Summary)"
    if (-not $val.Ok) {
        Write-Host "design validation FAILED with $($val.Errors.Count) error(s):" -ForegroundColor Yellow
        foreach ($e in $val.Errors) { Write-Host "  $e" -ForegroundColor Yellow }
        if ($Phase -ne 'Hardware') {
            throw "Design does not validate - phase '$Phase' will not run. -Force does not override this."
        }
        if (-not $Force) {
            throw ("Design does not validate. Fix it, or re-run with -Force to build HARDWARE " +
                   "only from the verified rack rows (safety logic is never generated from an " +
                   "invalid design).")
        }
        Write-Host "  -Force: continuing with the hardware phase only" -ForegroundColor Yellow
    }

    $model = Read-TiaSheetModel -Path $Path
    $proj  = $model.Project

    # --- hardware preconditions - these are never waived -------------------------------
    $fatal = @()
    foreach ($k in @('ProjectName','PlcName','CpuMLFB','SubnetName','IoSystemName')) {
        if (-not $proj[$k]) { $fatal += "10_Project: missing key '$k'" }
    }
    if (-not @($model.Zones).Count)   { $fatal += "20_Zones is empty" }
    if (-not @($model.Modules).Count) { $fatal += "21_Modules is empty" }
    foreach ($m in $model.Modules) {
        if (-not $m.MLFB)       { $fatal += "21_Modules $($m.Zone)/$($m.ModuleName): no MLFB" }
        if (-not $m.ModuleName) { $fatal += "21_Modules $($m.Zone) slot $($m.Slot): no ModuleName" }
    }
    foreach ($z in $model.Zones) {
        if (-not $z.Station) { $fatal += "20_Zones $($z.Zone): no Station name" }
        $isLocal = ($z.Zone -eq $proj['CpuLocalZone'])
        if (-not $isLocal -and -not $z.IM_MLFB) { $fatal += "20_Zones $($z.Zone): remote station needs IM_MLFB" }
    }
    if ($fatal.Count) {
        foreach ($f in $fatal) { Write-Host "  $f" -ForegroundColor Red }
        throw "Hardware rows are incomplete - $($fatal.Count) problem(s). These are never waived by -Force."
    }

    if (-not $ProjectPath) { $ProjectPath = $proj['ProjectPath'] }
    if (-not $ProjectPath) { $ProjectPath = Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) ('_out\' + $proj['ProjectName']) }
    $ProjectPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ProjectPath)

    $localZone = $proj['CpuLocalZone']
    Write-Host ("build: {0} -> {1}" -f $proj['ProjectName'], $ProjectPath)
    Write-Host ("  {0} zones, {1} modules, CPU {2} ({3} local: {4})" -f
        @($model.Zones).Count, @($model.Modules).Count, $proj['CpuMLFB'],
        $proj['PlcName'], $(if ($localZone) { $localZone } else { '(none)' }))

    # --- project + CPU ------------------------------------------------------------------
    if (Test-Path $ProjectPath) {
        if (-not $Force) { throw "Project folder already exists: $ProjectPath (use -Force to replace it)" }
        Remove-Item $ProjectPath -Recurse -Force
    }
    Connect-TiaPortal -New -WithUserInterface:$false | Out-Null
    $cpuFw = $proj['CpuFW']
    $cpuTid = "OrderNumber:$($proj['CpuMLFB'])" + $(if ($cpuFw) { if ($cpuFw -like '/*') { $cpuFw } else { "/$cpuFw" } } else { '' })
    New-TiaProject -Name $proj['ProjectName'] -Path (Split-Path -Parent $ProjectPath) | Out-Null
    New-TiaDevice -TypeIdentifier $cpuTid -Name $proj['PlcName'] | Out-Null
    $project = Get-TiaProject
    $cpuDev = $project.Devices | Where-Object { $_.Name -eq $proj['PlcName'] } | Select-Object -First 1
    if (-not $cpuDev) { throw "CPU '$($proj['PlcName'])' was not created." }

    $plugged = 0; $failed = @(); $stations = @()
    $niType = [Siemens.Engineering.HW.Features.NetworkInterface]

    # --- CPU-local zone: modules ride the CPU's own ET200SP rack ------------------------
    $cpuItems = Get-TiaDeviceItemTree -Device $cpuDev
    $localOk = $false
    if ($localZone) {
        $cpuRack = $cpuItems | Where-Object { $_.Name -eq 'Rack_0' } | Select-Object -First 1
        $localMods = @($model.ModulesByZone[$localZone] | Where-Object { $_.Kind -ne 'IM' } |
                       Sort-Object { [int]$_.Slot })
        if ($cpuRack -and $localMods.Count) {
            $localOk = $true
            foreach ($m in $localMods) {
                # slot 1 is the CPU itself on an ET200SP rack, so local modules shift up by 1
                $slot = [int]$m.Slot + 1
                $item = Add-TiaModuleProbed -Rack $cpuRack -OrderNumber $m.MLFB -Name $m.ModuleName -Slot $slot -Firmware $m.FW
                if ($item) { $plugged++ }
                else { $localOk = $false; $failed += "$localZone/$($m.ModuleName) @ CPU slot $slot"; break }
            }
        }
        if ($localOk) {
            Write-Host ("  {0,-9} {1,2} modules on the CPU rack" -f $localZone, $localMods.Count)
            $stations += [pscustomobject]@{ Zone = $localZone; Station = $proj['PlcName']; Device = $cpuDev; Local = $true }
        } else {
            Write-Host "  $localZone local plug failed - falling back to a remote station" -ForegroundColor Yellow
            $plugged = 0
        }
    }

    # --- one subnet + one IO system on the CPU ------------------------------------------
    $cpuNiItem = $cpuItems | Where-Object { $_.Name -match 'PROFINET' } | Select-Object -First 1
    if (-not $cpuNiItem) { throw "CPU has no PROFINET interface item." }
    $cpuNi = Get-TiaEngineeringService -Item $cpuNiItem -Type $niType
    $subnet = ($cpuNi.Nodes | Select-Object -First 1).CreateAndConnectToSubnet($proj['SubnetName'])
    $ctrl = $cpuNi.IoControllers | Select-Object -First 1
    $ioSystem = $ctrl.IoSystem
    if ($null -eq $ioSystem) { $ioSystem = $ctrl.CreateIoSystem($proj['IoSystemName']) }
    Write-Host ("  subnet '{0}', IO system '{1}'" -f $subnet.Name, $ioSystem.Name)

    # --- remote stations ------------------------------------------------------------------
    foreach ($z in $model.Zones) {
        if ($localOk -and $z.Zone -eq $localZone) { continue }
        $station = $z.Station
        $imFw = $z.IM_FW
        $imTid = "OrderNumber:$($z.IM_MLFB)" + $(if ($imFw) { if ($imFw -like '/*') { $imFw } else { "/$imFw" } } else { '' })
        $project.Devices.CreateWithItem($imTid, $station, $station) | Out-Null
        $iod = $project.Devices | Where-Object { $_.Name -eq $station } | Select-Object -First 1
        if (-not $iod) { throw "Station '$station' was not created (IM $imTid)." }

        $items = Get-TiaDeviceItemTree -Device $iod
        $rack = $items | Where-Object { $_.Name -eq 'Rack_0' } | Select-Object -First 1
        if (-not $rack) { throw "Station '$station' has no Rack_0." }

        $mods = @($model.ModulesByZone[$z.Zone] | Where-Object { $_.Kind -ne 'IM' } | Sort-Object { [int]$_.Slot })
        $n = 0
        foreach ($m in $mods) {
            $item = Add-TiaModuleProbed -Rack $rack -OrderNumber $m.MLFB -Name $m.ModuleName -Slot ([int]$m.Slot) -Firmware $m.FW
            if ($item) { $plugged++; $n++ }
            else { $failed += "$($z.Zone)/$($m.ModuleName) @ slot $($m.Slot) ($($m.MLFB))" }
        }

        $imNiItem = $items | Where-Object { $_.Name -match 'PROFINET' } | Select-Object -First 1
        if (-not $imNiItem) { throw "Station '$station' has no PROFINET interface." }
        $imNi = Get-TiaEngineeringService -Item $imNiItem -Type $niType
        ($imNi.Nodes | Select-Object -First 1).ConnectToSubnet($subnet)
        ($imNi.IoConnectors | Select-Object -First 1).ConnectToIoSystem($ioSystem)

        Write-Host ("  {0,-9} {1,2}/{2} modules -> IO system" -f $station, $n, $mods.Count)
        $stations += [pscustomobject]@{ Zone = $z.Zone; Station = $station; Device = $iod; Local = $false }
    }

    if ($failed.Count) {
        Write-Host "  $($failed.Count) module(s) FAILED to plug:" -ForegroundColor Red
        foreach ($f in $failed) { Write-Host "    $f" -ForegroundColor Red }
    }

    # --- compile --------------------------------------------------------------------------
    $plc = Get-TiaPlc | Select-Object -First 1
    $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
    $cErr = 0; $cWarn = 0
    try { $cErr = $compile.Errors; $cWarn = $compile.Warnings } catch { }
    Write-Host ("compile: state={0} errors={1} warnings={2}" -f $compile.State, $cErr, $cWarn)

    # --- address read-back ----------------------------------------------------------------
    # Addresses are ASSIGNED BY TIA, never authored in the sheet - this is the report that
    # closes the loop back to the design.
    $addr = @()
    foreach ($s in $stations) {
        $addr += Get-TiaModuleAddress -Device $s.Device -Zone $s.Zone -Station $s.Station
    }
    if (-not $ReportPath) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $Path)
        $ReportPath = Join-Path $repoRoot 'reports\90_AddressMap.csv'
    }
    $ReportPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ReportPath)
    $rdir = Split-Path -Parent $ReportPath
    if ($rdir -and -not (Test-Path $rdir)) { New-Item -ItemType Directory -Force $rdir | Out-Null }
    $addr | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding ASCII
    Write-Host ("addresses: {0} module rows -> {1}" -f $addr.Count, $ReportPath)

    if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }

    [pscustomobject]@{
        Ok           = ($failed.Count -eq 0 -and $cErr -eq 0)
        Phase        = $Phase
        ProjectPath  = $ProjectPath
        Zones        = @($model.Zones).Count
        Stations     = $stations.Count
        ModulesPlanned = @($model.Modules | Where-Object { $_.Kind -ne 'IM' }).Count
        ModulesPlugged = $plugged
        Failed       = $failed
        CompileState = [string]$compile.State
        CompileErrors= $cErr
        Addresses    = $ReportPath
    }
}
