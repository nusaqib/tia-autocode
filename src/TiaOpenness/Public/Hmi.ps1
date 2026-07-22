# Hmi.ps1 - WinCC HMI access (Comfort/Advanced HmiTarget and Unified).
# HMI Openness varies by WinCC flavor, so this layer is discovery-first: it finds
# HMI software, enumerates screens, round-trips screen XML (the supported authoring
# path), and exposes a reflection helper to reveal the exact collections available.

function Get-TiaHmi {
    <#
    .SYNOPSIS
        Enumerates HMI software (WinCC Comfort/Advanced HmiTarget or Unified) in the project.
    .DESCRIPTION
        Mirrors Get-TiaPlc: walks devices/device-items, returns each SoftwareContainer
        whose Software is NOT a PlcSoftware (i.e. an HMI runtime), with its .NET type.
    #>
    [CmdletBinding()]
    param([string]$Name, $Project)
    $project = Get-CurrentProject $Project
    $results = New-Object System.Collections.Generic.List[object]

    $svcType = [Siemens.Engineering.HW.Features.SoftwareContainer]
    $getSvc  = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($svcType)

    function Walk($item, $deviceName) {
        $container = $getSvc.Invoke($item, $null)
        if ($container -and $container.Software) {
            $sw = $container.Software
            if ($sw -isnot [Siemens.Engineering.SW.PlcSoftware]) {
                $results.Add([pscustomobject]@{
                    Name        = $sw.Name
                    Device      = $deviceName
                    SoftwareType= $sw.GetType().FullName
                    HmiSoftware = $sw
                })
            }
        }
        foreach ($c in $item.DeviceItems) { Walk $c $deviceName }
    }
    foreach ($device in $project.Devices) {
        foreach ($item in $device.DeviceItems) { Walk $item $device.Name }
    }
    if ($Name) { $results = $results | Where-Object { $_.Name -eq $Name -or $_.Device -eq $Name } }
    $results
}

function Resolve-HmiSoftware {
    param($Hmi)
    if (-not $Hmi) {
        $first = Get-TiaHmi | Select-Object -First 1
        if (-not $first) { throw "No HMI software found in the current project." }
        return $first.HmiSoftware
    }
    if ($Hmi.PSObject.Properties['HmiSoftware']) { return $Hmi.HmiSoftware }
    if ($Hmi -is [string]) {
        $m = Get-TiaHmi -Name $Hmi | Select-Object -First 1
        if (-not $m) { throw "No HMI named '$Hmi'." }
        return $m.HmiSoftware
    }
    return $Hmi   # assume it's already an HmiTarget/software object
}

function Show-TiaHmiApi {
    <#
    .SYNOPSIS
        Reflection dump of an HMI software object's collections/properties.
    .DESCRIPTION
        HMI collection names differ across WinCC Comfort/Advanced/Unified. Run this
        against a real HMI to discover the exact members (ScreenFolder, TagFolder,
        Connections, Cycles, ...) before scripting them.
    #>
    [CmdletBinding()]
    param($Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    Write-Host "HMI type: $($sw.GetType().FullName)"
    $sw.GetType().GetProperties() | Sort-Object Name | ForEach-Object {
        $val = try { $_.GetValue($sw) } catch { '<err>' }
        $kind = if ($val) { $val.GetType().Name } else { '<null>' }
        [pscustomobject]@{ Property = $_.Name; ValueType = $kind }
    }
}

function Get-TiaScreen {
    <#
    .SYNOPSIS
        Lists HMI screens (recursing screen folders) for Comfort/Advanced HmiTargets.
    #>
    [CmdletBinding()]
    param([string]$Name, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $root = $null
    foreach ($prop in 'ScreenFolder','Screens') {
        $p = $sw.GetType().GetProperty($prop); if ($p) { $root = $p.GetValue($sw); break }
    }
    if (-not $root) { throw "This HMI type exposes no ScreenFolder (type=$($sw.GetType().Name)). Use Show-TiaHmiApi to inspect." }

    $out = New-Object System.Collections.Generic.List[object]
    function Walk($folder, $path) {
        $screens = if ($folder.PSObject.Properties['Screens']) { $folder.Screens } else { $folder }
        foreach ($s in $screens) { $out.Add([pscustomobject]@{ Name = $s.Name; Folder = $path; Screen = $s }) }
        if ($folder.PSObject.Properties['Folders']) {
            foreach ($f in $folder.Folders) { Walk $f "$path/$($f.Name)" }
        }
    }
    Walk $root ''
    if ($Name) { $out = $out | Where-Object { $_.Name -like $Name } }
    $out
}

function Export-TiaScreen {
    <#
    .SYNOPSIS
        Exports an HMI screen to XML (the way to learn the schema / round-trip edits).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $s = (Get-TiaScreen -Hmi $Hmi -Name $Name | Select-Object -First 1).Screen
    if (-not $s) { throw "Screen '$Name' not found." }
    $fi = New-Object System.IO.FileInfo($Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ExportOptions]::WithDefaults } else { [Siemens.Engineering.ExportOptions]::None }
    $s.Export($fi, $opt)
    $Path
}

function Import-TiaScreen {
    <#
    .SYNOPSIS
        Imports an HMI screen from XML into the HMI's screen folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $folder = $sw.GetType().GetProperty('ScreenFolder').GetValue($sw)
    $fi = New-Object System.IO.FileInfo((Resolve-Path $Path).Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ImportOptions]::Override } else { [Siemens.Engineering.ImportOptions]::None }
    $folder.Screens.Import($fi, $opt)
}
