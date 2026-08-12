# Build a TIA project from a design sheet snapshot.
#
# The sheet IS the project definition: everything this cmdlet needs comes from design/csv,
# with no per-project scripts and no constants hidden in code. Schema: docs/DESIGN-SHEET.md.

function Invoke-TiaBuildFromSheet {
    <#
    .SYNOPSIS
        Build a TIA Portal project from a design-sheet CSV snapshot.
    .DESCRIPTION
        Phases, in dependency order - each one's output is the next one's input:

          Project     the project file and the CPU
          Hardware    one station per area, every module at its slot, one PROFINET subnet
                      + IO system, the station descriptions, and the assigned-address read-back
          UDTs        the authored device types plus one GENERATED type per area
          DB          one system F-DB with every area as a typed member
          Tags        one PLC tag per channel at its live address
          IOMap       FB_IOMap  - every channel copied into its DB member
          Certified   FB_Certified - ESTOP1 / SFDOOR / EV1oo2DI per 31_Policy
          Interlocks  FB_Safety - device summaries, area ANDs, the system AND, and the
                      safety runtime that calls the three blocks

        Validation gate, deliberately asymmetric:
          Project/Hardware  run Test-TiaDesignSheet and need -Force to proceed past
                    unrelated design errors, but ALWAYS refuse if their own rows are
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
        [ValidateSet('Project','Hardware','UDTs','DB','Tags','IOMap','Certified','Interlocks')][string]$Phase = 'Project',
        [switch]$Force,
        [switch]$Save,
        [switch]$RequireVerified,
        [string]$ReportPath
    )
    $ErrorActionPreference = 'Stop'
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path $Path)) { throw "No design snapshot at $Path" }

    
    # --- design gate ------------------------------------------------------------------
    # Scoped to the phase's OWN input tabs (the contract in docs/BUILD.md): a bad channel
    # row must not block UDT creation, which never reads that tab.
    # Anything global (stale snapshot, schema failure) blocks every phase.
    $phaseTabs = @{
        'Project'    = @('10_Project')
        'Hardware'   = @('10_Project','20_Stations','21_Modules')
        # Since v1.8 a device IS a member of its area's UDT, so every phase that used to
        # read 22_Devices reads 30_UDTs instead.
        'UDTs'       = @('30_UDTs')
        'DB'         = @('30_UDTs','32_Blocks')
        'Tags'       = @('23_Channels','21_Modules')
        'IOMap'      = @('23_Channels','30_UDTs')
        'Certified'  = @('31_Policy','33_SafetyBlocks','30_UDTs','23_Channels')
        'Interlocks' = @('34_Interlocks','34_Exclusions','30_UDTs')
    }
    $allTabs = @('10_Project','20_Stations','21_Modules','23_Channels','30_UDTs',
                 '31_Policy','32_Blocks','33_SafetyBlocks','34_Interlocks','34_Exclusions','35_Outputs')

    $val = Test-TiaDesignSheet -Path $Path -RequireVerified:$RequireVerified
    Write-Host "design: $($val.Summary)"
    $mine = @(); $other = @()
    foreach ($e in $val.Errors) {
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
        # Racks are inert, so Project/Hardware may be forced past their own errors.
        # Everything that ends up in the trip path may not - and -Force does not override it.
        if (@('Project','Hardware') -notcontains $Phase) {
            throw "Design errors in phase '$Phase' inputs - it will not run. -Force does not override this."
        }
        if (-not $Force) {
            throw ("Design does not validate. Fix it, or re-run with -Force to build the " +
                   "$Phase phase only from the verified rows.")
        }
        Write-Host "  -Force: continuing with the '$Phase' phase only" -ForegroundColor Yellow
    }

    $model = Read-TiaSheetModel -Path $Path
    $proj  = $model.Project
    # 10_Project's ProjectPath is relative TO THE DESIGN REPO, not to whatever directory the
    # caller happens to be sitting in - anchoring it on the shell's location silently built
    # one repo's design into another repo's _out.
    $repoRoot = Split-Path -Parent (Split-Path -Parent $Path)

    $ProjectPath = Resolve-TiaProjectPath -ProjectPath $ProjectPath -Project $proj -RepoRoot $repoRoot
    if (@('Project','Hardware') -notcontains $Phase) {
        $xmlDir = Join-Path $repoRoot '_out\xml'
        $amap = if ($ReportPath) { $ReportPath } else { Join-Path $repoRoot 'reports\90_AddressMap.csv' }
        switch ($Phase) {
            'UDTs' { return Invoke-TiaSheetTypePhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -Save:$Save }
            'DB'   { return Invoke-TiaSheetDataPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -Save:$Save }
            'Tags' { return Invoke-TiaSheetTagPhase -Model $model -ProjectPath $ProjectPath -AddressMapPath $amap -ReportDir (Join-Path $repoRoot 'reports') -Save:$Save }
            'IOMap'      { return Invoke-TiaSheetIOMapPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -AddressMapPath $amap -Save:$Save }
            'Certified'  { return Invoke-TiaSheetCertifiedPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -AddressMapPath $amap -Save:$Save }
            'Interlocks' { return Invoke-TiaSheetSafetyPhase -Model $model -ProjectPath $ProjectPath -XmlDir $xmlDir -AddressMapPath $amap -Save:$Save }
        }
    }

    # --- preconditions - these are never waived ----------------------------------------
    $fatal = @()
    foreach ($k in @('ProjectName','PlcName','CpuMLFB')) {
        if (-not $proj[$k]) { $fatal += "10_Project: missing key '$k'" }
    }
    if ($Phase -eq 'Hardware') {
        foreach ($k in @('SubnetName','IoSystemName')) {
            if (-not $proj[$k]) { $fatal += "10_Project: missing key '$k'" }
        }
        if (-not @($model.Stations).Count) { $fatal += "20_Stations is empty" }
        if (-not @($model.Modules).Count)  { $fatal += "21_Modules is empty" }
        foreach ($m in $model.Modules) {
            if (-not $m.MLFB)       { $fatal += "21_Modules $($m.Area)/$($m.ModuleName): no MLFB" }
            if (-not $m.ModuleName) { $fatal += "21_Modules $($m.Area) slot $($m.Slot): no ModuleName" }
        }
        foreach ($z in $model.Stations) {
            if (-not $z.Station_Name) { $fatal += "20_Stations $($z.Area): no Station name" }
            $isLocal = ($z.Area -eq $proj['CpuLocalArea'])
            if (-not $isLocal -and -not $z.IM_MLFB) { $fatal += "20_Stations $($z.Area): remote station needs IM_MLFB" }
        }
    }
    if ($fatal.Count) {
        foreach ($f in $fatal) { Write-Host "  $f" -ForegroundColor Red }
        throw "$Phase rows are incomplete - $($fatal.Count) problem(s). These are never waived by -Force."
    }

    $localArea = $proj['CpuLocalArea']
    Write-Host ("build: {0} -> {1}" -f $proj['ProjectName'], $ProjectPath)
    Write-Host ("  {0} areas, {1} modules, CPU {2} ({3} local: {4})" -f
        @($model.Stations).Count, @($model.Modules).Count, $proj['CpuMLFB'],
        $proj['PlcName'], $(if ($localArea) { $localArea } else { '(none)' }))

    # --- phase 1 'Project': the project file and the CPU, nothing else ------------------
    # Split from Hardware so the two questions stay separate: "does the project and CPU
    # exist" and "is the rack right". A CPU that will not create is a different problem
    # from a module that will not plug, and only this phase may destroy an existing
    # project folder.
    $cpuFw = $proj['CpuFW']
    $cpuTid = "OrderNumber:$($proj['CpuMLFB'])" + $(if ($cpuFw) { if ($cpuFw -like '/*') { $cpuFw } else { "/$cpuFw" } } else { '' })
    if ($Phase -eq 'Project') {
        if (Test-Path $ProjectPath) {
            if (-not $Force) { throw "Project folder already exists: $ProjectPath (use -Force to replace it)" }
            Remove-Item $ProjectPath -Recurse -Force
        }
        Connect-TiaPortal -New -WithUserInterface:$false | Out-Null
        try {
            New-TiaProject -Name $proj['ProjectName'] -Path (Split-Path -Parent $ProjectPath) | Out-Null
            New-TiaDevice -TypeIdentifier $cpuTid -Name $proj['PlcName'] | Out-Null
            $project = Get-TiaProject
            $cpuDev = $project.Devices | Where-Object { $_.Name -eq $proj['PlcName'] } | Select-Object -First 1
            if (-not $cpuDev) { throw "CPU '$($proj['PlcName'])' was not created ($cpuTid)." }
            Write-Host ("  project '{0}' + CPU '{1}' ({2})" -f $proj['ProjectName'], $proj['PlcName'], $proj['CpuMLFB'])
            $plc = Get-TiaPlc | Select-Object -First 1
            $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
            $cErr = 0; try { $cErr = $compile.Errors } catch { }
            Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
            if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
            return [pscustomobject]@{
                Ok = ($cErr -eq 0); Phase = 'Project'; ProjectPath = $ProjectPath
                Plc = $proj['PlcName']; Cpu = $proj['CpuMLFB']
                CompileState = [string]$compile.State; CompileErrors = $cErr
            }
        } finally { try { Disconnect-TiaPortal -Close | Out-Null } catch { } }
    }

    # --- phase 2 'Hardware': racks, modules, network ------------------------------------
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
    $project = Get-TiaProject
    $cpuDev = $project.Devices | Where-Object { $_.Name -eq $proj['PlcName'] } | Select-Object -First 1
    if (-not $cpuDev) { throw "CPU '$($proj['PlcName'])' is not in the project - run -Phase Project first." }

    $plugged = 0; $failed = @(); $stations = @(); $netWarn = @(); $netInherit = @(); $labelled = 0
    $niType = [Siemens.Engineering.HW.Features.NetworkInterface]
    # PROFIsafe parameters, applied where the sheet declares one and READ BACK either way.
    # An F-destination address TIA assigned and nobody recorded is a safety parameter no
    # review can check, so the built value lands in the address-map report regardless.
    $fParam = @(); $fWarn = @()

    # --- CPU-local area: modules ride the CPU's own ET200SP rack ------------------------
    $cpuItems = Get-TiaDeviceItemTree -Device $cpuDev
    $localOk = $false
    if ($localArea) {
        $cpuRack = $cpuItems | Where-Object { $_.Name -eq 'Rack_0' } | Select-Object -First 1
        $localMods = @($model.ModulesByArea[$localArea] | Where-Object { $_.Kind -ne 'IM' } |
                       Sort-Object { [int]$_.Slot })
        if ($cpuRack -and $localMods.Count) {
            $localOk = $true
            foreach ($m in $localMods) {
                # slot 1 is the CPU itself on an ET200SP rack, so local modules shift up by 1
                $slot = [int]$m.Slot + 1
                $item = Add-TiaModuleProbed -Rack $cpuRack -OrderNumber $m.MLFB -Name $m.ModuleName -Slot $slot -Firmware $m.FW
                if ($item -and $m.Kind -like 'F-*') {
                    $fp = Set-TiaModuleFParameter -Item $item -DestAddr $m.F_DestAddr -MonitorTime $m.F_MonitorTime
                    if ($fp.IsFModule) {
                        foreach ($e in $fp.Failed) { $fWarn += "$localArea/$($m.ModuleName): $e" }
                        $fParam += [pscustomobject]@{ Area = $localArea; Module = $m.ModuleName
                            DeclaredDestAddr = [string]$m.F_DestAddr; DeclaredMonitorTime = [string]$m.F_MonitorTime
                            BuiltDestAddr = [string]$fp.Actual['Failsafe_FDestinationAddress']
                            BuiltMonitorTime = [string]$fp.Actual['Failsafe_FMonitoringtime'] }
                    }
                }
                if ($item) { $plugged++ }
                else { $localOk = $false; $failed += "$localArea/$($m.ModuleName) @ CPU slot $slot"; break }
            }
        }
        if ($localOk) {
            Write-Host ("  {0,-9} {1,2} modules on the CPU rack" -f $localArea, $localMods.Count)
            $stations += [pscustomobject]@{ Area = $localArea; Station = $proj['PlcName']; Device = $cpuDev; Local = $true }
        } else {
            Write-Host "  $localArea local plug failed - falling back to a remote station" -ForegroundColor Yellow
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
    # the CPU takes its addressing from the local area's station row, so the controller is
    # declared in the same place as every device it controls
    if ($localArea) {
        $lz = @($model.Stations | Where-Object { $_.Area -eq $localArea }) | Select-Object -First 1
        if ($lz) {
            $cn = Set-TiaStationNetwork -Node ($cpuNi.Nodes | Select-Object -First 1) -Interface $cpuNi `
                      -IpAddress $lz.IP_Address -SubnetMask $lz.Subnet_Mask -DeviceName $lz.Device_Name
            foreach ($f in $cn.Failed) { $netWarn += "$($proj['PlcName']) : $f" }
            foreach ($i in $cn.Inherited) { $netInherit += "$($proj['PlcName']):$i" }
            if ($cn.Applied.Count) { Write-Host ("  CPU network: " + ($cn.Applied -join ' ')) }
            if (Set-TiaDeviceComment -Device $cpuDev -Comment ([string]$lz.Description)) { $labelled++ }
        }
    }
    Write-Host ("  subnet '{0}', IO system '{1}'" -f $subnet.Name, $ioSystem.Name)

    # --- remote stations ------------------------------------------------------------------
    foreach ($z in $model.Stations) {
        if ($localOk -and $z.Area -eq $localArea) { continue }
        $station = $z.Station_Name
        $imFw = $z.IM_FW
        $imTid = "OrderNumber:$($z.IM_MLFB)" + $(if ($imFw) { if ($imFw -like '/*') { $imFw } else { "/$imFw" } } else { '' })
        $project.Devices.CreateWithItem($imTid, $station, $station) | Out-Null
        $iod = $project.Devices | Where-Object { $_.Name -eq $station } | Select-Object -First 1
        if (-not $iod) { throw "Station '$station' was not created (IM $imTid)." }

        if (Set-TiaDeviceComment -Device $iod -Comment ([string]$z.Description)) { $labelled++ }

        $items = Get-TiaDeviceItemTree -Device $iod
        $rack = $items | Where-Object { $_.Name -eq 'Rack_0' } | Select-Object -First 1
        if (-not $rack) { throw "Station '$station' has no Rack_0." }

        $mods = @($model.ModulesByArea[$z.Area] | Where-Object { $_.Kind -ne 'IM' } | Sort-Object { [int]$_.Slot })
        $n = 0
        foreach ($m in $mods) {
            $item = Add-TiaModuleProbed -Rack $rack -OrderNumber $m.MLFB -Name $m.ModuleName -Slot ([int]$m.Slot) -Firmware $m.FW
            if ($item -and $m.Kind -like 'F-*') {
                $fp = Set-TiaModuleFParameter -Item $item -DestAddr $m.F_DestAddr -MonitorTime $m.F_MonitorTime
                if ($fp.IsFModule) {
                    foreach ($e in $fp.Failed) { $fWarn += "$($z.Area)/$($m.ModuleName): $e" }
                    $fParam += [pscustomobject]@{ Area = $z.Area; Module = $m.ModuleName
                        DeclaredDestAddr = [string]$m.F_DestAddr; DeclaredMonitorTime = [string]$m.F_MonitorTime
                        BuiltDestAddr = [string]$fp.Actual['Failsafe_FDestinationAddress']
                        BuiltMonitorTime = [string]$fp.Actual['Failsafe_FMonitoringtime'] }
                }
            }
            if ($item) { $plugged++; $n++ }
            else { $failed += "$($z.Area)/$($m.ModuleName) @ slot $($m.Slot) ($($m.MLFB))" }
        }

        $imNiItem = $items | Where-Object { $_.Name -match 'PROFINET' } | Select-Object -First 1
        if (-not $imNiItem) { throw "Station '$station' has no PROFINET interface." }
        $imNi = Get-TiaEngineeringService -Item $imNiItem -Type $niType
        $imNode = $imNi.Nodes | Select-Object -First 1
        $imNode.ConnectToSubnet($subnet)
        ($imNi.IoConnectors | Select-Object -First 1).ConnectToIoSystem($ioSystem)

        $net = Set-TiaStationNetwork -Node $imNode -Interface $imNi -IpAddress $z.IP_Address `
                   -SubnetMask $z.Subnet_Mask -DeviceNumber $z.Device_Number -DeviceName $z.Device_Name
        foreach ($f in $net.Failed) { $netWarn += "$station : $f" }
        foreach ($i in $net.Inherited) { $netInherit += "${station}:$i" }

        Write-Host ("  {0,-9} {1,2}/{2} modules -> IO system{3}" -f $station, $n, $mods.Count,
                    $(if ($net.Applied.Count) { '  ' + ($net.Applied -join ' ') } else { '' }))
        $stations += [pscustomobject]@{ Area = $z.Area; Station = $station; Device = $iod; Local = $false }
    }

    Write-Host ("  station descriptions written to device comments: {0}" -f $labelled)
    if ($fParam.Count) {
        $declared = @($fParam | Where-Object { $_.DeclaredDestAddr })
        Write-Host ("  PROFIsafe: {0} F-module(s), {1} with a declared F_DestAddr, {2} auto-assigned by TIA" -f
                    $fParam.Count, $declared.Count, ($fParam.Count - $declared.Count))
        # An F-destination address must be unique network-wide, and the compiler does NOT
        # check it - a whole rack can sit on one address and still compile 0 errors.
        #
        # TIA only runs its own auto-assignment through the GUI. In an Openness-only build
        # every module keeps the catalogue default, so with nothing declared they ALL
        # collide. That is "not assigned yet", not a build defect, so it is reported as an
        # unmissable warning. Once ANY address is declared, a collision is a real fault and
        # fails the phase.
        $dupes = @($fParam | Where-Object { $_.BuiltDestAddr } | Group-Object BuiltDestAddr | Where-Object { $_.Count -gt 1 })
        $anyDeclared = [bool]$declared.Count
        foreach ($d in $dupes) {
            $who = ($d.Group | ForEach-Object { "$($_.Area)/$($_.Module)" }) -join ', '
            if ($anyDeclared) {
                Write-Host ("  DUPLICATE F-destination address {0}: {1}" -f $d.Name, $who) -ForegroundColor Red
                $failed += "duplicate F_DestAddr $($d.Name) on $who"
            } else {
                Write-Host ("  {0} F-module(s) share F-destination address {1}" -f $d.Group.Count, $d.Name) -ForegroundColor Yellow
            }
        }
        if ($dupes.Count -and -not $anyDeclared) {
            Write-Host "  TIA does not auto-assign F-destination addresses through Openness - every" -ForegroundColor Yellow
            Write-Host "  F-module keeps the catalogue default and the compiler does not object." -ForegroundColor Yellow
            Write-Host "  Fill 21_Modules.F_DestAddr to match the BaseUnit DIP switches." -ForegroundColor Yellow
        }
    }
    if ($fWarn.Count) {
        Write-Host "  $($fWarn.Count) PROFIsafe parameter(s) could not be set:" -ForegroundColor Yellow
        foreach ($w in $fWarn) { Write-Host "    $w" -ForegroundColor Yellow }
    }
    if ($netInherit.Count) {
        # Not a failure: an IO device whose IP is assigned by the controller has no writable
        # SubnetMask. Reported so the sheet value is not mistaken for something that was applied.
        $names = @($netInherit | ForEach-Object { ($_ -split ':')[0] })
        Write-Host ("  {0} station(s) inherit SubnetMask from the IO controller (not writable per device): {1}" -f
                    $names.Count, ($names -join ', ')) -ForegroundColor DarkGray
    }
    if ($netWarn.Count) {
        Write-Host "  $($netWarn.Count) network attribute(s) could not be set (names vary by TIA version):" -ForegroundColor Yellow
        foreach ($w in $netWarn) { Write-Host "    $w" -ForegroundColor Yellow }
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
        $addr += Get-TiaModuleAddress -Device $s.Device -Area $s.Area -Station $s.Station
    }
    # Attach the PROFIsafe values the modules actually hold. TIA assigns an F-destination
    # address when the sheet leaves it blank, and an assigned safety parameter that nothing
    # records cannot be reviewed - so it is reported here whether declared or not.
    $fByKey = @{}
    foreach ($f in $fParam) { $fByKey["$($f.Area)/$($f.Module)"] = $f }
    foreach ($a in $addr) {
        $f = $fByKey["$($a.Area)/$($a.Module)"]
        $a | Add-Member -NotePropertyName F_DestAddr    -NotePropertyValue $(if ($f) { $f.BuiltDestAddr } else { '' })
        $a | Add-Member -NotePropertyName F_MonitorTime -NotePropertyValue $(if ($f) { $f.BuiltMonitorTime } else { '' })
        $a | Add-Member -NotePropertyName F_Declared    -NotePropertyValue $(if ($f -and $f.DeclaredDestAddr) { 'Yes' } elseif ($f) { 'No' } else { '' })
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

    # InputBytes is DECLARED in the sheet but never used to compute an address - the build
    # reads InputBase back from TIA, and only byte 0 of an F-DI carries channel values. So a
    # wrong footprint produces a correct program and a wrong record, and nothing complains.
    # TIA has just laid the rack out, so the gap to the next module's base IS the footprint:
    # compare them here rather than maintaining a part-number table that would go stale.
    $declBytes = @{}
    foreach ($m in $model.Modules) { $declBytes["$($m.Area)/$($m.ModuleName)"] = $m }
    $byArea = @{}
    foreach ($a in $addr) {
        if ([string]::IsNullOrWhiteSpace([string]$a.InputBase)) { continue }
        if (-not $byArea.ContainsKey($a.Area)) { $byArea[$a.Area] = @() }
        $byArea[$a.Area] += $a
    }
    $fpWarn = @()
    foreach ($ar in $byArea.Keys) {
        $list = @($byArea[$ar] | Sort-Object { [int]$_.InputBase })
        for ($i = 0; $i -lt $list.Count - 1; $i++) {
            $gap = [int]$list[$i+1].InputBase - [int]$list[$i].InputBase
            if ($gap -le 0) { continue }        # not contiguous - says nothing about size
            $row = $declBytes["$ar/$($list[$i].Module)"]
            if (-not $row -or -not $row.InputBytes) { continue }
            $decl = [int]$row.InputBytes
            if ($decl -ne $gap) {
                $fpWarn += ("  {0}/{1} ({2}): 21_Modules says InputBytes={3}, TIA laid it out {4} byte(s) wide" -f
                            $ar, $list[$i].Module, $row.MLFB, $decl, $gap)
            }
        }
    }
    if ($fpWarn.Count) {
        Write-Host ("  {0} module(s) declare an InputBytes that does not match the footprint TIA gave them:" -f $fpWarn.Count) -ForegroundColor Yellow
        foreach ($w in $fpWarn) { Write-Host $w -ForegroundColor Yellow }
        Write-Host "  Addresses are read back from TIA, so the program is unaffected - the DESIGN RECORD is wrong." -ForegroundColor Yellow
    }

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
        Areas        = @($model.Stations).Count
        Stations     = $stations.Count
        ModulesPlanned = @($model.Modules | Where-Object { $_.Kind -ne 'IM' }).Count
        ModulesPlugged = $plugged
        Failed       = $failed
        CompileState = [string]$compile.State
        CompileErrors= $cErr
        Addresses    = $ReportPath
    }
}
