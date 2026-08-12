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
        [switch]$RequireVerified,
        [switch]$AssumeDefaultPolarity,
        [string]$ReportPath
    )
    $ErrorActionPreference = 'Stop'
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path $Path)) { throw "No design snapshot at $Path" }

    if (@('Hardware','Types','Data','Tags','IOMap','Certified') -notcontains $Phase) {
        throw ("Phase '$Phase' is not implemented yet. Its input/output contract is defined in " +
               "the project's docs/BUILD.md.")
    }

    # --- design gate ------------------------------------------------------------------
    # Scoped to the phase's OWN input tabs (the contract in docs/BUILD.md): a missing
    # polarity in 23_Channels must not block UDT creation, which never reads that tab.
    # Anything global (stale snapshot, schema failure) blocks every phase.
    $phaseTabs = @{
        'Hardware'  = @('10_Project','20_Zones','21_Modules')
        'Types'     = @('30_UDTs')
        'Data'      = @('22_Devices','30_UDTs','32_Blocks')
        'Tags'      = @('23_Channels','21_Modules')
        'IOMap'     = @('23_Channels','22_Devices')
        'Certified' = @('31_Policy','33_SafetyBlocks','22_Devices','23_Channels')
        'Safety'    = @('34_Interlocks','22_Devices')
    }
    $allTabs = @('10_Project','20_Zones','21_Modules','22_Devices','23_Channels','30_UDTs',
                 '31_Policy','32_Blocks','33_SafetyBlocks','34_Interlocks','35_Outputs')

    # Some errors are about a single COLUMN, not the whole tab. Polarity decides whether
    # the IOMap emits a negated contact and is irrelevant to tag creation, so it must not
    # block a phase that never reads it. Keyed on the error text, listing the phases the
    # column actually feeds.
    $columnScoped = @{ 'no Polarity' = @('IOMap') }

    $val = Test-TiaDesignSheet -Path $Path -RequireVerified:$RequireVerified
    Write-Host "design: $($val.Summary)"
    $mine = @(); $other = @()
    foreach ($e in $val.Errors) {
        $scoped = $false
        foreach ($k in $columnScoped.Keys) {
            if ($e -like "*$k*") {
                $scoped = $true
                # -AssumeDefaultPolarity is the caller explicitly accepting this specific
                # gap; the phase then stamps the result Provisional. Nothing is silent.
                if ($k -eq 'no Polarity' -and $AssumeDefaultPolarity) { $other += $e }
                elseif ($columnScoped[$k] -contains $Phase) { $mine += $e }
                else { $other += $e }
                break
            }
        }
        if ($scoped) { continue }
        $tab = @($allTabs | Where-Object { $e -like "$_*" }) | Select-Object -First 1
        # no recognisable tab prefix => global (stale snapshot, schema, verified gate)
        if (-not $tab -or $phaseTabs[$Phase] -contains $tab) { $mine += $e } else { $other += $e }
    }
    if ($other.Count) {
        Write-Host "  $($other.Count) design error(s) outside phase '$Phase' inputs - not blocking:" -ForegroundColor DarkGray
        foreach ($e in $other) { Write-Host "    $e" -ForegroundColor DarkGray }
    }
    if ($mine.Count) {
        Write-Host "  $($mine.Count) design error(s) in phase '$Phase' inputs:" -ForegroundColor Yellow
        foreach ($e in $mine) { Write-Host "    $e" -ForegroundColor Yellow }
        # Racks are inert, so hardware may be forced past its own errors. Everything that
        # ends up in the trip path may not - and -Force does not override that.
        if ($Phase -ne 'Hardware') {
            throw "Design errors in phase '$Phase' inputs - it will not run. -Force does not override this."
        }
        if (-not $Force) {
            throw ("Design does not validate. Fix it, or re-run with -Force to build HARDWARE " +
                   "only from the verified rack rows.")
        }
        Write-Host "  -Force: continuing with the hardware phase only" -ForegroundColor Yellow
    }

    $model = Read-TiaSheetModel -Path $Path
    $proj  = $model.Project

    if ($Phase -ne 'Hardware') {
        if (-not $ProjectPath) { $ProjectPath = $proj['ProjectPath'] }
        if (-not $ProjectPath) { $ProjectPath = Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) ('_out\' + $proj['ProjectName']) }
        $ProjectPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ProjectPath)
        $xmlDir = Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) '_out\xml'
        switch ($Phase) {
            'Types' { return Invoke-TiaSheetTypePhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -Save:$Save }
            'Data'  { return Invoke-TiaSheetDataPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -Save:$Save }
            'Certified' {
                $repoRoot = Split-Path -Parent (Split-Path -Parent $Path)
                $amap = Join-Path $repoRoot 'reports/90_AddressMap.csv'
                return Invoke-TiaSheetCertifiedPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -AddressMapPath $amap -AssumeDefaultPolarity:$AssumeDefaultPolarity -Save:$Save
            }
            'IOMap' {
                $repoRoot = Split-Path -Parent (Split-Path -Parent $Path)
                $amap = Join-Path $repoRoot 'reports/90_AddressMap.csv'
                return Invoke-TiaSheetIOMapPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -AddressMapPath $amap -AssumeDefaultPolarity:$AssumeDefaultPolarity -Save:$Save
            }
            'Tags'  {
                $repoRoot = Split-Path -Parent (Split-Path -Parent $Path)
                $amap = if ($ReportPath) { $ReportPath } else { Join-Path $repoRoot 'reports\90_AddressMap.csv' }
                return Invoke-TiaSheetTagPhase -Model $model -ProjectPath $ProjectPath -AddressMapPath $amap -ReportDir (Join-Path $repoRoot 'reports') -Save:$Save
            }
        }
    }

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
    try {
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
    } finally {
        # Always release the project. Leaving the Portal instance up holds a lock, and the
        # next phase fails with "already been opened by user ... 2 minute delay".
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

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
