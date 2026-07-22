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

# --- HMI connections -------------------------------------------------------

function Get-TiaHmiConnection {
    <#
    .SYNOPSIS
        Lists the HMI's communication connections (link to a PLC).
    .DESCRIPTION
        Reflection-based: connection collections vary by WinCC flavor. Returns each
        connection's Name and .NET type. Confirm the member with Show-TiaHmiApi if empty.
    #>
    [CmdletBinding()]
    param([string]$Name, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $conns = $null
    foreach ($p in 'Connections','ConnectionFolder') {
        $x = $sw.GetType().GetProperty($p); if ($x) { $conns = $x.GetValue($sw); break }
    }
    if ($null -eq $conns) { return @() }
    if ($conns.PSObject.Properties['Connections']) { $conns = $conns.Connections }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $conns) { $out.Add([pscustomobject]@{ Name = $c.Name; Type = $c.GetType().Name; Connection = $c }) }
    if ($Name) { $out = $out | Where-Object { $_.Name -eq $Name } }
    $out
}

# --- HMI tags --------------------------------------------------------------

function Resolve-HmiTagTable {
    # Finds (or creates) the HmiTagTable to author into. Discovery-first because
    # TagFolder/DefaultTagTable/TagTables member names vary by WinCC flavor.
    param($sw, [string]$TagTable)
    $tf = $null
    foreach ($p in 'TagFolder','Tags') { $x = $sw.GetType().GetProperty($p); if ($x) { $tf = $x.GetValue($sw); break } }
    if (-not $tf) { throw "HMI '$($sw.Name)' exposes no TagFolder (type=$($sw.GetType().Name)). Use Show-TiaHmiApi to inspect." }

    # A specific, named table was requested: find it under TagTables (recursing folders) or create it.
    if ($TagTable) {
        $tables = if ($tf.PSObject.Properties['TagTables']) { $tf.TagTables } else { $null }
        if ($tables) {
            $hit = $tables | Where-Object { $_.Name -eq $TagTable } | Select-Object -First 1
            if ($hit) { return $hit }
            $created = try { $tables.Create($TagTable) } catch { $null }
            if ($created) { return $created }
        }
    }
    # Default: the DefaultTagTable if present, else the first table, else the folder itself.
    if ($tf.PSObject.Properties['DefaultTagTable'] -and $tf.DefaultTagTable) { return $tf.DefaultTagTable }
    if ($tf.PSObject.Properties['TagTables'] -and @($tf.TagTables).Count) { return @($tf.TagTables)[0] }
    return $tf
}

function Get-TiaHmiTag {
    <#
    .SYNOPSIS
        Lists HMI tags (across tag tables) for the HMI. Reflection-based.
    #>
    [CmdletBinding()]
    param([string]$Name, [string]$TagTable, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $tf = $null
    foreach ($p in 'TagFolder','Tags') { $x = $sw.GetType().GetProperty($p); if ($x) { $tf = $x.GetValue($sw); break } }
    if (-not $tf) { throw "HMI '$($sw.Name)' exposes no TagFolder. Use Show-TiaHmiApi." }

    $tables = New-Object System.Collections.Generic.List[object]
    if ($tf.PSObject.Properties['DefaultTagTable'] -and $tf.DefaultTagTable) { $tables.Add($tf.DefaultTagTable) }
    if ($tf.PSObject.Properties['TagTables']) { foreach ($t in $tf.TagTables) { $tables.Add($t) } }
    if ($tf.PSObject.Properties['Folders']) { foreach ($f in $tf.Folders) { if ($f.PSObject.Properties['TagTables']) { foreach ($t in $f.TagTables) { $tables.Add($t) } } } }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tables) {
        if ($TagTable -and $t.Name -ne $TagTable) { continue }
        $tags = if ($t.PSObject.Properties['Tags']) { $t.Tags } else { $t }
        foreach ($g in $tags) {
            $out.Add([pscustomobject]@{
                Name       = $g.Name
                TagTable   = $t.Name
                DataType   = (Get-Safe { $g.DataTypeName })
                Connection = (Get-Safe { $g.Connection })
                Tag        = $g
            })
        }
    }
    if ($Name) { $out = $out | Where-Object { $_.Name -like $Name } }
    $out
}

function New-TiaHmiTag {
    <#
    .SYNOPSIS
        Creates (or updates) an HMI tag. Discovery-first / reflection-based.
    .DESCRIPTION
        HMI tag object models differ across WinCC Comfort/Advanced/Unified. This finds
        the tag collection, calls its Create(name), then sets DataType/Connection/
        PlcTag/Comment/Acquisition via whichever property setters exist on this install.
        For internal (non-connected) tags, leave -Connection empty. If the members do
        not match this HMI flavor it throws with a hint to run Show-TiaHmiApi.
    .PARAMETER Name       HMI tag name.
    .PARAMETER DataType   HMI datatype (Bool, Int, Real, ...).
    .PARAMETER Connection Connection name for an external tag; empty = internal tag.
    .PARAMETER PlcTag     Source PLC tag / DB member (external tags).
    .PARAMETER Address    Explicit address, when the flavor addresses by string.
    .PARAMETER TagTable   Target tag table (created if missing); default table otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DataType,
        [string]$Connection,
        [string]$PlcTag,
        [string]$Address,
        [string]$Acquisition,
        [string]$Comment,
        [string]$TagTable,
        $Hmi
    )
    $sw = Resolve-HmiSoftware $Hmi
    $table = Resolve-HmiTagTable $sw $TagTable
    $coll = if ($table.PSObject.Properties['Tags']) { $table.Tags } else { $table }

    $tag = $coll | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $tag) {
        $create = $coll.GetType().GetMethod('Create', [type[]]@([string]))
        if (-not $create) { throw "HMI tag collection (type=$($coll.GetType().Name)) has no Create(string). Run Show-TiaHmiApi and author via Import-TiaHmiTagTable XML instead." }
        $tag = $create.Invoke($coll, @($Name))
    }
    function TrySet($obj, $prop, $val) {
        if ($null -eq $val -or $val -eq '') { return }
        $p = $obj.GetType().GetProperty($prop)
        if ($p -and $p.CanWrite) { try { $p.SetValue($obj, $val) } catch {} }
    }
    TrySet $tag 'DataTypeName' $DataType
    TrySet $tag 'Comment'      $Comment
    if ($Connection) { TrySet $tag 'Connection' $Connection }
    if ($PlcTag)     { TrySet $tag 'PlcTag'     $PlcTag }
    if ($Address)    { TrySet $tag 'AddressString' $Address; TrySet $tag 'LogicalAddress' $Address }
    if ($Acquisition){ TrySet $tag 'AcquisitionCycleName' $Acquisition }
    $tag
}

# --- HMI tag tables & alarms: XML round-trip (schema-exact, version-safe) ---

function Export-TiaHmiTagTable {
    <#
    .SYNOPSIS
        Exports an HMI tag table to XML (learn the schema / back up / round-trip).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $tf = $sw.GetType().GetProperty('TagFolder').GetValue($sw)
    $table = $null
    if ($tf.PSObject.Properties['DefaultTagTable'] -and $tf.DefaultTagTable.Name -eq $Name) { $table = $tf.DefaultTagTable }
    if (-not $table -and $tf.PSObject.Properties['TagTables']) { $table = $tf.TagTables | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    if (-not $table) { throw "HMI tag table '$Name' not found." }
    $fi = New-Object System.IO.FileInfo($Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ExportOptions]::WithDefaults } else { [Siemens.Engineering.ExportOptions]::None }
    $table.Export($fi, $opt)
    $Path
}

function Import-TiaHmiTagTable {
    <#
    .SYNOPSIS
        Imports an HMI tag table from XML into the HMI's tag folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $tf = $sw.GetType().GetProperty('TagFolder').GetValue($sw)
    $coll = if ($tf.PSObject.Properties['TagTables']) { $tf.TagTables } else { throw "HMI TagFolder has no TagTables collection; run Show-TiaHmiApi." }
    $fi = New-Object System.IO.FileInfo((Resolve-Path $Path).Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ImportOptions]::Override } else { [Siemens.Engineering.ImportOptions]::None }
    $coll.Import($fi, $opt)
}

function Get-TiaHmiAlarmCollection {
    # Locate the discrete/analog alarm collection (name varies by flavor).
    param($sw, [ValidateSet('Discrete','Analog')][string]$Kind)
    $prop = if ($Kind -eq 'Analog') { 'AnalogAlarms' } else { 'DiscreteAlarms' }
    $x = $sw.GetType().GetProperty($prop)
    if (-not $x) { throw "HMI '$($sw.Name)' exposes no $prop (type=$($sw.GetType().Name)). Use Show-TiaHmiApi." }
    $x.GetValue($sw)
}

function Export-TiaHmiAlarms {
    <#
    .SYNOPSIS
        Exports HMI discrete or analog alarms to XML for editing / round-trip.
    #>
    [CmdletBinding()]
    param([ValidateSet('Discrete','Analog')][string]$Kind = 'Discrete',
          [Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $coll = Get-TiaHmiAlarmCollection $sw $Kind
    $fi = New-Object System.IO.FileInfo($Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ExportOptions]::WithDefaults } else { [Siemens.Engineering.ExportOptions]::None }
    $coll.Export($fi, $opt)
    $Path
}

function Import-TiaHmiAlarms {
    <#
    .SYNOPSIS
        Imports HMI discrete or analog alarms from XML.
    #>
    [CmdletBinding()]
    param([ValidateSet('Discrete','Analog')][string]$Kind = 'Discrete',
          [Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $coll = Get-TiaHmiAlarmCollection $sw $Kind
    $fi = New-Object System.IO.FileInfo((Resolve-Path $Path).Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ImportOptions]::Override } else { [Siemens.Engineering.ImportOptions]::None }
    $coll.Import($fi, $opt)
}
