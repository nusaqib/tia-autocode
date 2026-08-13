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

function New-TiaHmiDevice {
    <#
    .SYNOPSIS
        Adds a WinCC HMI panel (device) to the current project from a catalog order number.
    .DESCRIPTION
        Same CreateWithItem path as New-TiaDevice, but for an HMI station. The order
        number + panel image version must match a panel installed in your TIA catalog.
        Validated live on V19: KTP700 Comfort = 'OrderNumber:6AV2 124-1GC01-0AX0/17.0.0.0'.
        Other Comfort MLFBs (TP700 0GC01, TP1200 0MC01, ...) follow the same shape; the
        version segment (e.g. /17.0.0.0) is the panel image and varies by install.
    .PARAMETER OrderNumber
        Catalog identifier. 'OrderNumber:' is prepended automatically if omitted.
    .PARAMETER Name
        HMI station (device) name, e.g. HMI_1.
    .PARAMETER DeviceItemName
        Name for the panel device item (defaults to the station name).
    .EXAMPLE
        New-TiaHmiDevice -OrderNumber '6AV2 124-1GC01-0AX0/17.0.0.0' -Name HMI_1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrderNumber,
        [Parameter(Mandatory)][string]$Name,
        [string]$DeviceItemName,
        $Project
    )
    $project = Get-CurrentProject $Project
    $tid = if ($OrderNumber -like 'OrderNumber:*') { $OrderNumber } else { "OrderNumber:$OrderNumber" }
    if (-not $DeviceItemName) { $DeviceItemName = $Name }
    Write-Verbose "Creating HMI device '$Name' ($tid)..."
    [void]$project.Devices.CreateWithItem($tid, $DeviceItemName, $Name)
    Get-TiaHmi -Name $Name | Select-Object -First 1
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

function Set-HmiProperty {
    # Sets a property, converting the value to the property's real CLR type first.
    # Unified is inconsistent here: a screen item's Left/Top are Int32 but its
    # Width/Height are UInt32, so passing a PowerShell [int] straight in throws
    # "Object of type 'System.Int32' cannot be converted to type 'System.UInt32'".
    param($Object, [string]$Property, $Value)
    $p = $Object.GetType().GetProperty($Property)
    if (-not $p -or -not $p.CanWrite) { return $false }
    $t = $p.PropertyType
    if ($t.IsGenericType -and $t.GetGenericTypeDefinition() -eq [Nullable`1]) { $t = $t.GetGenericArguments()[0] }
    $p.SetValue($Object, [Convert]::ChangeType($Value, $t))
    $true
}

function Resolve-HmiScreenRoot {
    # Locates the screen collection and reports which WinCC flavor this HMI is.
    #
    #   Classic  (Comfort/Advanced, Siemens.Engineering.Hmi.HmiTarget)
    #            -> sw.ScreenFolder, which owns .Screens and nested .Folders.
    #            Screens support Export()/Import() - the XML round-trip is the ONLY
    #            authoring path, because objects cannot be created through the API.
    #   Unified  (Unified Comfort Panel / PC RT, HmiUnified.HmiSoftware)
    #            -> sw.Screens directly. There is NO ScreenFolder, and HmiScreen has
    #            NO Export()/Import() - only Delete(). Authoring is done by creating
    #            objects and setting properties (see New-TiaScreen/New-TiaScreenItem).
    param($sw)
    $p = $sw.GetType().GetProperty('ScreenFolder')
    if ($p) {
        $folder = $p.GetValue($sw)
        return [pscustomobject]@{ Flavor = 'Classic'; Folder = $folder; Screens = $folder.Screens }
    }
    $p = $sw.GetType().GetProperty('Screens')
    if ($p) {
        return [pscustomobject]@{ Flavor = 'Unified'; Folder = $null; Screens = $p.GetValue($sw) }
    }
    throw "HMI '$($sw.Name)' exposes neither ScreenFolder nor Screens (type=$($sw.GetType().Name)). Run Show-TiaHmiApi to inspect."
}

function Get-TiaScreen {
    <#
    .SYNOPSIS
        Lists HMI screens. Handles both Comfort/Advanced (ScreenFolder, recursing
        sub-folders) and Unified (a flat Screens composition).
    #>
    [CmdletBinding()]
    param([string]$Name, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $root = Resolve-HmiScreenRoot $sw

    $out = New-Object System.Collections.Generic.List[object]
    function Walk($node, $path) {
        $screens = if ($node.PSObject.Properties['Screens']) { $node.Screens } else { $node }
        foreach ($s in $screens) {
            $out.Add([pscustomobject]@{ Name = $s.Name; Folder = $path; Flavor = $root.Flavor; Screen = $s })
        }
        if ($node.PSObject.Properties['Folders']) {
            foreach ($f in $node.Folders) { Walk $f "$path/$($f.Name)" }
        }
    }
    if ($root.Flavor -eq 'Classic') { Walk $root.Folder '' } else { Walk $root.Screens '' }
    if ($Name) { $out = $out | Where-Object { $_.Name -like $Name } }
    $out
}

function Export-TiaScreen {
    <#
    .SYNOPSIS
        Exports an HMI screen to XML (Comfort/Advanced only - Unified has no screen XML).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $s = (Get-TiaScreen -Hmi $Hmi -Name $Name | Select-Object -First 1).Screen
    if (-not $s) { throw "Screen '$Name' not found." }
    if (-not $s.GetType().GetMethod('Export')) {
        throw ("Screen '$Name' is a $($s.GetType().Name) (WinCC Unified) and has no Export() - " +
               "Unified screens are not XML round-trippable. Author them through the object " +
               "model instead: New-TiaScreen / New-TiaScreenItem / Set-TiaScreenItemTag.")
    }
    $fi = New-Object System.IO.FileInfo($Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ExportOptions]::WithDefaults } else { [Siemens.Engineering.ExportOptions]::None }
    $s.Export($fi, $opt)
    $Path
}

function Import-TiaScreen {
    <#
    .SYNOPSIS
        Imports an HMI screen from XML (Comfort/Advanced only - Unified has no screen XML).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $root = Resolve-HmiScreenRoot $sw
    # Was: $sw.GetType().GetProperty('ScreenFolder').GetValue($sw) - null-refs on Unified,
    # which has no ScreenFolder at all. Resolve the flavor and say so plainly instead.
    if (-not $root.Screens.GetType().GetMethod('Import')) {
        throw ("This HMI is WinCC $($root.Flavor) ($($root.Screens.GetType().Name)) and its screen " +
               "collection has no Import() - Unified screens are not XML round-trippable. " +
               "Author them through the object model instead: New-TiaScreen / New-TiaScreenItem.")
    }
    $fi = New-Object System.IO.FileInfo((Resolve-Path $Path).Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ImportOptions]::Override } else { [Siemens.Engineering.ImportOptions]::None }
    $root.Screens.Import($fi, $opt)
}

function New-TiaScreen {
    <#
    .SYNOPSIS
        Creates an HMI screen (returns the existing one if the name is already taken).
    .DESCRIPTION
        WinCC Unified exposes Screens.Create(name), so screens can be generated directly.
        Classic Comfort/Advanced compositions generally do not - there the supported path
        is Import-TiaScreen with screen XML, and this cmdlet says so rather than failing
        with a missing-method error.
    .PARAMETER Name    Screen name.
    .PARAMETER Width   Screen width in pixels (set when the property is writable).
    .PARAMETER Height  Screen height in pixels.
    .EXAMPLE
        New-TiaScreen -Name Overview -Width 1920 -Height 1080
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [int]$Width, [int]$Height, $Hmi)
    $sw = Resolve-HmiSoftware $Hmi
    $root = Resolve-HmiScreenRoot $sw
    $screen = @($root.Screens) | Where-Object { $_ -and $_.Name -eq $Name } | Select-Object -First 1
    if ($screen) {
        # Idempotent: an existing screen is reused, but explicitly requested geometry is
        # still applied, so re-running a generator converges instead of silently skipping.
        Write-Verbose "Screen '$Name' already exists; applying requested properties."
        foreach ($pair in @(@('Width', $Width), @('Height', $Height))) {
            if ($PSBoundParameters.ContainsKey($pair[0])) { [void](Set-HmiProperty $screen $pair[0] $pair[1]) }
        }
        return $screen
    }

    $create = $root.Screens.GetType().GetMethod('Create', [type[]]@([string]))
    if (-not $create) {
        throw ("WinCC $($root.Flavor) ($($root.Screens.GetType().Name)) has no Create(string) for " +
               "screens. Author the screen as XML and apply it with Import-TiaScreen.")
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create HMI screen')) { return }
    $screen = $create.Invoke($root.Screens, @($Name))
    foreach ($pair in @(@('Width', $Width), @('Height', $Height))) {
        if ($PSBoundParameters.ContainsKey($pair[0])) { [void](Set-HmiProperty $screen $pair[0] $pair[1]) }
    }
    $screen
}

function Resolve-HmiScreenItemType {
    # Maps a short widget name to a concrete Unified screen-item type. Accepts the exact
    # type name ('HmiIOField'), the un-prefixed name ('IOField'), or the full name. The
    # types live across several namespaces (UI.Widgets, UI.Shapes, UI.Controls), so match
    # on every public non-abstract type under Siemens.Engineering.HmiUnified.UI.
    param([string]$TypeName)
    $asm = [Siemens.Engineering.HmiUnified.HmiSoftware].Assembly
    $cands = $asm.GetTypes() | Where-Object {
        $_.IsPublic -and -not $_.IsAbstract -and $_.Namespace -like 'Siemens.Engineering.HmiUnified.UI.*'
    }
    $hit = $cands | Where-Object { $_.FullName -eq $TypeName } | Select-Object -First 1
    if (-not $hit) { $hit = $cands | Where-Object { $_.Name -eq $TypeName } | Select-Object -First 1 }
    if (-not $hit) { $hit = $cands | Where-Object { $_.Name -eq "Hmi$TypeName" } | Select-Object -First 1 }
    if (-not $hit) {
        $known = ($cands | Where-Object { $_.Namespace -like '*.Widgets' -or $_.Namespace -like '*.Shapes' } |
                  ForEach-Object { $_.Name } | Sort-Object) -join ', '
        throw "Unknown HMI screen item type '$TypeName'. Known widget/shape types: $known"
    }
    $hit
}

function New-TiaScreenItem {
    <#
    .SYNOPSIS
        Adds an object (IO field, button, label, rectangle, ...) to a WinCC Unified screen.
    .DESCRIPTION
        Unified's ScreenItems.Create is a GENERIC method - Create<T>(string name) - and
        Windows PowerShell 5.1 has no syntax for calling generic methods, so this resolves
        the widget type by name and invokes it through MakeGenericMethod. Position and size
        are applied afterwards via property setters.
    .PARAMETER Screen    Screen name (or a screen object).
    .PARAMETER Name      Object name, unique within the screen.
    .PARAMETER Type      Widget type: HmiIOField, HmiButton, HmiLabel, HmiRectangle, ...
                         The 'Hmi' prefix is optional.
    .EXAMPLE
        New-TiaScreenItem -Screen HOME -Name Gate_BTA -Type HmiButton -Left 40 -Top 40 -Width 160 -Height 60
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Screen,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [int]$Left, [int]$Top, [int]$Width, [int]$Height,
        $Hmi
    )
    $target = if ($Screen -is [string]) {
        $m = Get-TiaScreen -Hmi $Hmi -Name $Screen | Select-Object -First 1
        if (-not $m) { throw "Screen '$Screen' not found." }
        $m.Screen
    } else { $Screen }

    $items = $target.ScreenItems
    if ($null -eq $items) { throw "Screen '$($target.Name)' exposes no ScreenItems (this is a Unified-only cmdlet)." }
    $t = Resolve-HmiScreenItemType $Type
    $item = @($items) | Where-Object { $_ -and $_.Name -eq $Name } | Select-Object -First 1
    if ($item) {
        # Idempotent: reuse the object but still apply requested geometry, so re-running a
        # generator converges. Refuse if the name is taken by a DIFFERENT widget type -
        # silently returning the wrong kind of object is how a screen ends up subtly wrong.
        if ($item.GetType() -ne $t) {
            throw "Screen '$($target.Name)' already has an item named '$Name' of type $($item.GetType().Name), not $($t.Name)."
        }
        Write-Verbose "Screen item '$Name' already exists; applying requested properties."
    } else {
        $create = $items.GetType().GetMethods() | Where-Object {
            $_.Name -eq 'Create' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1
        } | Select-Object -First 1
        if (-not $create) { throw "ScreenItems ($($items.GetType().Name)) has no generic Create<T>(string)." }
        if (-not $PSCmdlet.ShouldProcess("$($target.Name)/$Name", "Create $($t.Name)")) { return }
        $item = $create.MakeGenericMethod($t).Invoke($items, @($Name))
    }

    foreach ($pair in @(@('Left', $Left), @('Top', $Top), @('Width', $Width), @('Height', $Height))) {
        if ($PSBoundParameters.ContainsKey($pair[0])) { [void](Set-HmiProperty $item $pair[0] $pair[1]) }
    }
    $item
}

function Set-TiaScreenItemTag {
    <#
    .SYNOPSIS
        Binds a WinCC Unified screen-item property to an HMI tag (a TagDynamization).
    .DESCRIPTION
        Unified dynamizes a property by creating a dynamization on it and pointing that at
        a tag - e.g. an IO field's ProcessValue, a rectangle's BackColor. Dynamizations
        .Create<T>(propertyName) is generic, so it goes through MakeGenericMethod too. An
        existing dynamization on the same property is reused, not duplicated.
    .PARAMETER Property  Property to dynamize, e.g. ProcessValue, Visible, BackColor.
    .PARAMETER Tag       HMI tag name to bind to.
    .EXAMPLE
        Set-TiaScreenItemTag -Screen HOME -Item Gate_BTA -Property ProcessValue -Tag BTA_Gate_OK
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Screen,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Property,
        [Parameter(Mandatory)][string]$Tag,
        $Hmi
    )
    $target = if ($Screen -is [string]) {
        $m = Get-TiaScreen -Hmi $Hmi -Name $Screen | Select-Object -First 1
        if (-not $m) { throw "Screen '$Screen' not found." }
        $m.Screen
    } else { $Screen }
    $obj = @($target.ScreenItems) | Where-Object { $_ -and $_.Name -eq $Item } | Select-Object -First 1
    if (-not $obj) { throw "Screen item '$Item' not found on screen '$($target.Name)'." }

    $dyns = $obj.Dynamizations
    if ($null -eq $dyns) { throw "Screen item '$Item' exposes no Dynamizations (Unified-only cmdlet)." }
    $dyn = @($dyns) | Where-Object { $_ -and $_.PropertyName -eq $Property } | Select-Object -First 1
    if (-not $dyn) {
        $create = $dyns.GetType().GetMethods() | Where-Object {
            $_.Name -eq 'Create' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1
        } | Select-Object -First 1
        if (-not $create) { throw "Dynamizations ($($dyns.GetType().Name)) has no generic Create<T>(string)." }
        if (-not $PSCmdlet.ShouldProcess("$($target.Name)/$Item.$Property", "Bind to tag '$Tag'")) { return }
        $tagDyn = [Siemens.Engineering.HmiUnified.HmiSoftware].Assembly.GetType('Siemens.Engineering.HmiUnified.UI.Dynamization.TagDynamization')
        $dyn = $create.MakeGenericMethod($tagDyn).Invoke($dyns, @($Property))
    }
    $p = $dyn.GetType().GetProperty('Tag')
    if (-not $p -or -not $p.CanWrite) { throw "TagDynamization on '$Property' has no writable Tag property." }
    $p.SetValue($dyn, $Tag)
    $dyn
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
    $tagsProp = if ($table) { $table.PSObject.Properties['Tags'] } else { $null }
    $coll = if ($tagsProp -and $null -ne $table.Tags) { $table.Tags } else { $table }
    # Note: $coll may be an EMPTY composition - test for $null explicitly, since PowerShell
    # treats an empty enumerable as falsy (so `-not $coll` would wrongly fire here).
    if ($null -eq $coll) { throw "Could not resolve an HMI tag collection on '$($sw.Name)'. Run Show-TiaHmiApi to inspect." }

    $tag = @($coll) | Where-Object { $_ -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $tag) {
        # WinCC Comfort/Advanced 'TagComposition' exposes only CreateFrom(MasterCopy) -
        # no Create(string) - so tags there must come from XML import or a master copy.
        $create = $coll.GetType().GetMethod('Create', [type[]]@([string]))
        if (-not $create) {
            throw ("This HMI flavor ($($coll.GetType().Name)) has no Create(string) for tags. " +
                   "On WinCC Comfort/Advanced, author HMI tags by exporting a tag table " +
                   "(Export-TiaHmiTagTable), editing the XML, and re-importing " +
                   "(Import-TiaHmiTagTable) - the DataType is a typed link, not a plain string.")
        }
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
