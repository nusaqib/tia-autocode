# Hardware helpers shared by the sheet-driven builder. Private so the module's public
# surface stays the documented cmdlet set.

# An MLFB alone is usually NOT a valid type identifier - Openness wants a firmware suffix
# ("6ES7136-6BA01-0CA0/V1.1"). The catalogue version differs per module and per TIA
# install, so the sheet's FW value is tried first and these are the fallback probes.
$script:TiaFwProbe = @{
    '6ES7136-6BA01-0CA0' = @('/V1.0','/V1.1')
    '6ES7136-6BA00-0CA0' = @('/V1.0','/V1.1')
    '6ES7132-6BH01-0BA0' = @('/V0.0')
    '6ES7131-6BH01-0BA0' = @('/V0.0')
    '6ES7136-6DC00-0CA0' = @('/V1.0','/V1.1')
    '6ES7136-6RA00-0BF0' = @('/V1.0','/V1.1')
}
$script:TiaFwProbeDefault = @('/V1.0','/V1.1','/V2.0','/V0.0','/V2.1','')

function Get-TiaEngineeringService {
    <#
    .SYNOPSIS
        item.GetService<T>() - the generic call PowerShell cannot express directly.
    #>
    param($Item, [Type]$Type)
    $mi = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($Type)
    $mi.Invoke($Item, $null)
}

function Get-TiaDeviceItemTree {
    <#
    .SYNOPSIS
        Flatten a device's DeviceItems recursively (racks, interfaces, modules).
    #>
    param($Device)
    $acc = New-Object System.Collections.Generic.List[object]
    function Walk-Item($item) {
        $acc.Add($item)
        foreach ($c in $item.DeviceItems) { Walk-Item $c }
    }
    foreach ($di in $Device.DeviceItems) { Walk-Item $di }
    $acc
}

function Add-TiaModuleProbed {
    <#
    .SYNOPSIS
        Plug a module by MLFB, probing firmware suffixes until one is accepted.
    .DESCRIPTION
        Returns the plugged item, or $null when no suffix is pluggable at that slot.
        Tries $Firmware first when the sheet supplies one, so a project can pin an exact
        catalogue version rather than taking whatever probes first.
    #>
    param($Rack, [string]$OrderNumber, [string]$Name, [int]$Slot, [string]$Firmware)
    $vers = @()
    if ($Firmware) { $vers += $(if ($Firmware -like '/*') { $Firmware } else { "/$Firmware" }) }
    $vers += $(if ($script:TiaFwProbe.ContainsKey($OrderNumber)) { $script:TiaFwProbe[$OrderNumber] }
               else { $script:TiaFwProbeDefault })
    foreach ($v in ($vers | Select-Object -Unique)) {
        $tid = "OrderNumber:$OrderNumber$v"
        $can = $false
        try { $can = $Rack.CanPlugNew($tid, '', $Slot) } catch { $can = $false }
        if ($can) {
            try { return $Rack.PlugNew($tid, $Name, $Slot) } catch { }
        }
    }
    $null
}

function Get-TiaUdtBuildOrder {
    <#
    .SYNOPSIS
        Order UDT names so every type is created after the types it references.
    .DESCRIPTION
        A UDT whose member is another UDT cannot be created first - TIA rejects the
        unknown type. Returns the names in a safe creation order and throws on a
        dependency cycle (which would otherwise fail as a confusing "unknown type").
    #>
    param([Parameter(Mandatory)]$Rows)
    $members = @{}
    foreach ($r in $Rows) {
        if (-not $r.UDT) { continue }
        if (-not $members.ContainsKey($r.UDT)) { $members[$r.UDT] = @() }
        $members[$r.UDT] += $r
    }
    $names = @($members.Keys)
    $deps = @{}
    foreach ($n in $names) {
        $d = @()
        foreach ($m in $members[$n]) {
            $t = ([string]$m.Datatype).Trim().Trim('"')
            if ($names -contains $t -and $t -ne $n) { $d += $t }
        }
        $deps[$n] = @($d | Select-Object -Unique)
    }
    $order = New-Object System.Collections.Generic.List[string]
    $state = @{}   # 1 = visiting, 2 = done
    function Visit-Udt([string]$n, $path) {
        if ($state[$n] -eq 2) { return }
        if ($state[$n] -eq 1) { throw "30_UDTs: circular reference $($path -join ' -> ') -> $n" }
        $state[$n] = 1
        foreach ($d in $deps[$n]) { Visit-Udt $d ($path + $n) }
        $state[$n] = 2
        $order.Add($n)
    }
    foreach ($n in ($names | Sort-Object)) { Visit-Udt $n @() }
    $order
}

function Set-TiaStationNetwork {
    <#
    .SYNOPSIS
        Apply the declared PROFINET addressing to a station's interface.
    .DESCRIPTION
        Blank values are left alone, so TIA keeps assigning them - the sheet declares only
        what it wants pinned. Each attribute is set independently and failures are returned
        rather than thrown: the exact attribute names vary by TIA version, and a naming
        mismatch must not abort a build that is otherwise correct.
    .PARAMETER Node
        The interface Node (from NetworkInterface.Nodes).
    .PARAMETER Interface
        The NetworkInterface service object.
    #>
    param($Node, $Interface, [string]$IpAddress, [string]$SubnetMask,
          [string]$DeviceNumber, [string]$DeviceName)
    $applied = @(); $failed = @()

    if ($IpAddress -and $Node) {
        try { $Node.SetAttribute('Address', $IpAddress); $applied += "ip=$IpAddress" }
        catch { $failed += "Address: $($_.Exception.Message)" }
    }
    if ($SubnetMask -and $Node) {
        try { $Node.SetAttribute('SubnetMask', $SubnetMask); $applied += "mask=$SubnetMask" }
        catch { $failed += "SubnetMask: $($_.Exception.Message)" }
    }
    if ($DeviceName -and $Node) {
        # the PROFINET name is generated from the station name unless auto-generation is
        # switched off first, so the order matters
        try { $Node.SetAttribute('PnDeviceNameAutoGeneration', $false) } catch { }
        foreach ($attr in @('PnDeviceName','DeviceName')) {
            try { $Node.SetAttribute($attr, $DeviceName); $applied += "pnname=$DeviceName"; break }
            catch { $failed += "${attr}: $($_.Exception.Message)" }
        }
    }
    if ($DeviceNumber -and $Interface) {
        $n = 0
        if ([int]::TryParse($DeviceNumber, [ref]$n)) {
            $conn = $Interface.IoConnectors | Select-Object -First 1
            if ($conn) {
                foreach ($attr in @('PnDeviceNumber','DeviceNumber')) {
                    try { $conn.SetAttribute($attr, $n); $applied += "devno=$n"; break }
                    catch { $failed += "${attr}: $($_.Exception.Message)" }
                }
            }
        } else { $failed += "DeviceNumber '$DeviceNumber' is not an integer" }
    }
    [pscustomobject]@{ Applied = $applied; Failed = $failed }
}

function Set-TiaDeviceComment {
    <#
    .SYNOPSIS
        Write the as-built label onto a device's Comment (device properties / network view).
    .DESCRIPTION
        This is where a rack label like "SAFETY RACK S1014" belongs: TIA exposes a writable
        Comment on the Device and on its head DeviceItem, and no plant-designation field is
        reachable through Openness. Without it, StationLabel would be a column the build
        declares and never applies.
    #>
    param($Device, [string]$Comment)
    if (-not $Comment -or -not $Device) { return $null }
    # SetAttribute on the Device itself does NOT throw and does NOT persist, so a
    # non-throwing call is not evidence of success - read it back. The head DeviceItem is
    # the target that actually holds the comment shown in device properties.
    foreach ($target in @(($Device.DeviceItems | Select-Object -First 1), $Device)) {
        if (-not $target) { continue }
        try {
            $target.SetAttribute('Comment', $Comment)
            if ([string]$target.GetAttribute('Comment') -eq $Comment) { return $Comment }
        } catch { }
    }
    $null
}

function Get-TiaModuleAddress {
    <#
    .SYNOPSIS
        Input/output start addresses of every addressable item under a device.
    #>
    param($Device, [string]$Area, [string]$Station)
    $rows = @()
    foreach ($m in (Get-TiaDeviceItemTree -Device $Device)) {
        $inB = $null; $outB = $null
        try {
            foreach ($a in $m.Addresses) {
                if ($a.IoType -eq 'Input'  -and $null -eq $inB)  { $inB  = $a.StartAddress }
                if ($a.IoType -eq 'Output' -and $null -eq $outB) { $outB = $a.StartAddress }
            }
        } catch { }
        if ($null -ne $inB -or $null -ne $outB) {
            $rows += [pscustomobject]@{
                Area = $Area; Station = $Station; Module = $m.Name
                InputBase = $inB; OutputBase = $outB
            }
        }
    }
    $rows
}
