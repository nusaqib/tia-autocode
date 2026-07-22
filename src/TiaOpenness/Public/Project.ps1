function New-TiaProject {
    <#
    .SYNOPSIS
        Creates a new TIA project and makes it current.
    .PARAMETER Path
        Directory in which the project folder is created.
    .PARAMETER Name
        Project name (folder + .apXX file base name).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Path,
        $Portal
    )
    $portal = Get-CurrentPortal $Portal
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $dir = New-Object System.IO.DirectoryInfo($Path)
    Write-Verbose "Creating project '$Name' under $Path ..."
    $project = $portal.Projects.Create($dir, $Name)
    $script:TiaSession.Project = $project
    $project
}

function Open-TiaProject {
    <#
    .SYNOPSIS
        Opens an existing TIA project file (.apXX) and makes it current.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectFile,
        $Portal
    )
    $portal = Get-CurrentPortal $Portal
    if (-not (Test-Path $ProjectFile)) { throw "Project file not found: $ProjectFile" }
    $fi = New-Object System.IO.FileInfo($ProjectFile)
    Write-Verbose "Opening project $ProjectFile ..."
    $project = $portal.Projects.Open($fi)
    $script:TiaSession.Project = $project
    $project
}

function Get-TiaProject {
    <#
    .SYNOPSIS
        Returns the current (or all open) TIA project(s).
    #>
    [CmdletBinding()]
    param([switch]$All, $Portal)
    $portal = Get-CurrentPortal $Portal
    if ($All) { return @($portal.Projects) }
    Get-CurrentProject
}

function Save-TiaProject {
    <#
    .SYNOPSIS
        Saves the current (or a given) TIA project to disk.
    #>
    [CmdletBinding()] param($Project)
    (Get-CurrentProject $Project).Save()
}

function Close-TiaProject {
    <#
    .SYNOPSIS
        Saves (unless -NoSave) and closes the current project.
    #>
    [CmdletBinding()]
    param([switch]$NoSave, $Project)
    $p = Get-CurrentProject $Project
    if (-not $NoSave) { $p.Save() }
    $p.Close()
    if ($script:TiaSession.Project -eq $p) { $script:TiaSession.Project = $null }
}

function New-TiaDevice {
    <#
    .SYNOPSIS
        Adds a CPU/device to the current project from a catalog type identifier.
    .DESCRIPTION
        The type identifier (MLFB / order number) must match a CPU installed in your
        TIA hardware catalog, e.g.:
            OrderNumber:6ES7 511-1AK02-0AB0/V2.9   (S7-1511)
            OrderNumber:6ES7 315-2EH14-0AB0/V3.2   (S7-315)
        Find valid identifiers by exporting an existing device, or from the catalog.
    .PARAMETER TypeIdentifier
        Catalog identifier, typically "OrderNumber:<MLFB>/<FWVersion>".
    .PARAMETER Name
        Device (station) name.
    .PARAMETER DeviceItemName
        Name for the CPU device item (defaults to the device name).
    .EXAMPLE
        New-TiaDevice -TypeIdentifier 'OrderNumber:6ES7 511-1AK02-0AB0/V2.9' -Name 'PLC_1'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeIdentifier,
        [Parameter(Mandatory)][string]$Name,
        [string]$DeviceItemName,
        $Project
    )
    $project = Get-CurrentProject $Project
    if (-not $DeviceItemName) { $DeviceItemName = $Name }
    Write-Verbose "Creating device '$Name' ($TypeIdentifier)..."
    $device = $project.Devices.CreateWithItem($TypeIdentifier, $DeviceItemName, $Name)
    [pscustomobject]@{ Name = $device.Name; TypeIdentifier = $TypeIdentifier; Device = $device }
}

function Get-TiaPlc {
    <#
    .SYNOPSIS
        Enumerates PLC software containers (CPUs) in the project.
    .DESCRIPTION
        Walks Devices -> DeviceItems, finds each item exposing a SoftwareContainer
        whose Software is a PlcSoftware, and returns a friendly wrapper carrying the
        underlying PlcSoftware object needed by the tag/block commands.
    .EXAMPLE
        Get-TiaPlc | Format-Table Name, Device
    #>
    [CmdletBinding()]
    param([string]$Name, $Project)
    $project = Get-CurrentProject $Project

    $results = New-Object System.Collections.Generic.List[object]

    function Get-SoftwareFromDeviceItem($item) {
        # SoftwareContainer is reached via GetService<T>() on a DeviceItem.
        $svcType = [Siemens.Engineering.HW.Features.SoftwareContainer]
        $mi = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($svcType)
        $container = $mi.Invoke($item, $null)
        if ($container) { return $container.Software }
        return $null
    }

    function Walk-DeviceItems($item, $deviceName) {
        $sw = Get-SoftwareFromDeviceItem $item
        if ($sw -and $sw -is [Siemens.Engineering.SW.PlcSoftware]) {
            $results.Add([pscustomobject]@{
                Name        = $sw.Name
                Device      = $deviceName
                DeviceItem  = $item.Name
                PlcSoftware = $sw
            })
        }
        foreach ($child in $item.DeviceItems) { Walk-DeviceItems $child $deviceName }
    }

    foreach ($device in $project.Devices) {
        foreach ($item in $device.DeviceItems) { Walk-DeviceItems $item $device.Name }
    }

    if ($Name) { $results = $results | Where-Object { $_.Name -eq $Name -or $_.Device -eq $Name } }
    $results
}

function Resolve-PlcSoftware {
    # Internal: accept a Get-TiaPlc wrapper, a raw PlcSoftware, or nothing (=> first PLC).
    param($Plc)
    if (-not $Plc) {
        $first = Get-TiaPlc | Select-Object -First 1
        if (-not $first) { throw "No PLC found in the current project." }
        return $first.PlcSoftware
    }
    if ($Plc -is [Siemens.Engineering.SW.PlcSoftware]) { return $Plc }
    if ($Plc.PSObject.Properties['PlcSoftware']) { return $Plc.PlcSoftware }
    if ($Plc -is [string]) {
        $match = Get-TiaPlc -Name $Plc | Select-Object -First 1
        if (-not $match) { throw "No PLC named '$Plc' in the current project." }
        return $match.PlcSoftware
    }
    throw "Unrecognized -Plc value; pass a Get-TiaPlc result, a PlcSoftware, or a PLC name."
}
