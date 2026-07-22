# Hardware.ps1 - device rack layout: read modules and plug new ones from a spreadsheet.

function Get-TiaDeviceList {
    <#
    .SYNOPSIS
        Lists the stations/devices in the current project.
    #>
    [CmdletBinding()]
    param($Project)
    $project = Get-CurrentProject $Project
    foreach ($d in $project.Devices) {
        [pscustomobject]@{ Name = $d.Name; TypeIdentifier = (Get-Safe { $d.TypeIdentifier }); Device = $d }
    }
}

function Get-TiaModule {
    <#
    .SYNOPSIS
        Lists the hardware modules (with slot + order number) under a device's rack.
    .DESCRIPTION
        Great for discovering the exact module order numbers (MLFB) valid in your
        catalog before authoring a modules spreadsheet.
    #>
    [CmdletBinding()]
    param([string]$DeviceName, $Project)
    $project = Get-CurrentProject $Project
    $devices = $project.Devices
    if ($DeviceName) { $devices = $devices | Where-Object { $_.Name -eq $DeviceName } }

    $out = New-Object System.Collections.Generic.List[object]
    function Walk($item, $devName) {
        $type = Get-Safe { $item.GetAttribute('TypeIdentifier') }
        $pos  = Get-Safe { $item.PositionNumber }
        if ($type) {
            $out.Add([pscustomobject]@{
                Device = $devName; Slot = $pos; Name = $item.Name; OrderNumber = $type; Item = $item
            })
        }
        foreach ($c in $item.DeviceItems) { Walk $c $devName }
    }
    foreach ($d in $devices) { foreach ($i in $d.DeviceItems) { Walk $i $d.Name } }
    $out
}

function Add-TiaModule {
    <#
    .SYNOPSIS
        Plugs a hardware module into a device rack at a slot (PlugNew).
    .DESCRIPTION
        Locates a rack object under the device that accepts the module (CanPlugNew)
        and plugs it. The type identifier is an MLFB, e.g.
        "OrderNumber:6ES7 521-1BL00-0AB0/V2.0" (a bare "6ES7 ..." is prefixed for you).
        Discover valid order numbers with Get-TiaModule against an existing station.
    .PARAMETER DeviceName
        Target station/device name.
    .PARAMETER Slot
        Rack position number.
    .PARAMETER OrderNumber
        Module MLFB / type identifier.
    .PARAMETER Name
        Name for the new module.
    .EXAMPLE
        Add-TiaModule -DeviceName PLC_1 -Slot 2 -OrderNumber '6ES7 521-1BL00-0AB0/V2.0' -Name DI_16
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeviceName,
        [Parameter(Mandatory)][int]$Slot,
        [Parameter(Mandatory)][string]$OrderNumber,
        [Parameter(Mandatory)][string]$Name,
        $Project
    )
    $project = Get-CurrentProject $Project
    $device = $project.Devices | Where-Object { $_.Name -eq $DeviceName } | Select-Object -First 1
    if (-not $device) { throw "Device '$DeviceName' not found." }

    $typeId = if ($OrderNumber -match '^OrderNumber:') { $OrderNumber } else { "OrderNumber:$OrderNumber" }

    # Collect candidate rack objects: the device and every DeviceItem (recursive).
    $candidates = New-Object System.Collections.Generic.List[object]
    function Collect($item) { $candidates.Add($item); foreach ($c in $item.DeviceItems) { Collect $c } }
    foreach ($i in $device.DeviceItems) { Collect $i }

    foreach ($c in $candidates) {
        $canPlug = $false
        try { $canPlug = $c.CanPlugNew($typeId, $Name, $Slot) } catch { $canPlug = $false }
        if ($canPlug) {
            $item = $c.PlugNew($typeId, $Name, $Slot)
            return [pscustomobject]@{ Device = $DeviceName; Slot = $Slot; Name = $Name; OrderNumber = $typeId; Item = $item }
        }
    }
    throw "Could not plug '$OrderNumber' at slot $Slot on '$DeviceName' - no rack accepts it (bad MLFB, occupied slot, or incompatible). Use Get-TiaModule on an existing station to find valid order numbers."
}
