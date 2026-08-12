# Read a design-sheet CSV snapshot into a structured model.
# Schema contract: docs/DESIGN-SHEET.md. Consumed by Invoke-TiaBuildFromSheet.

function Get-TiaXlsxSheetName {
    <#
    .SYNOPSIS
        Tab names of an .xlsx, in workbook order (dependency-free: zip + xl/workbook.xml).
    #>
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $e = $zip.Entries | Where-Object { $_.FullName -eq 'xl/workbook.xml' }
        if (-not $e) { throw "not an xlsx (no xl/workbook.xml): $Path" }
        $sr = New-Object System.IO.StreamReader($e.Open())
        try { $xml = [xml]$sr.ReadToEnd() } finally { $sr.Close() }
        @($xml.workbook.sheets.sheet | ForEach-Object { $_.name })
    } finally { $zip.Dispose() }
}

function Read-TiaSheetModel {
    <#
    .SYNOPSIS
        Load design/csv into a model: Project, Zones, Modules, Devices, Channels, Udts,
        Blocks, SafetyBlocks, Interlocks - with per-zone indexes the builder needs.
    #>
    param([Parameter(Mandatory)][string]$Path)

    function T($n) {
        $f = Join-Path $Path "$n.csv"
        if (-not (Test-Path $f)) { return @() }
        @(Import-Csv $f)
    }

    $proj = @{}
    foreach ($r in (T '10_Project')) { if ($r.Key) { $proj[$r.Key] = [string]$r.Value } }

    $m = [ordered]@{
        Project      = $proj
        Zones        = T '20_Zones'
        Modules      = T '21_Modules'
        Devices      = T '22_Devices'
        Channels     = T '23_Channels'
        Udts         = T '30_UDTs'
        Policy       = T '31_Policy'
        Blocks       = T '32_Blocks'
        SafetyBlocks = T '33_SafetyBlocks'
        Interlocks   = T '34_Interlocks'
        Outputs      = T '35_Outputs'
    }
    $model = [pscustomobject]$m

    # indexes
    $devById = @{}; foreach ($d in $model.Devices) { $devById[$d.DeviceID] = $d }
    $model | Add-Member -NotePropertyName DeviceById -NotePropertyValue $devById

    $chanByDev = @{}
    foreach ($c in $model.Channels) {
        if (-not $chanByDev.ContainsKey($c.DeviceID)) { $chanByDev[$c.DeviceID] = @() }
        $chanByDev[$c.DeviceID] += $c
    }
    $model | Add-Member -NotePropertyName ChannelsByDevice -NotePropertyValue $chanByDev

    $modByZone = @{}
    foreach ($x in $model.Modules) {
        if (-not $modByZone.ContainsKey($x.Zone)) { $modByZone[$x.Zone] = @() }
        $modByZone[$x.Zone] += $x
    }
    $model | Add-Member -NotePropertyName ModulesByZone -NotePropertyValue $modByZone

    $devByZone = @{}
    foreach ($d in $model.Devices) {
        if (-not $devByZone.ContainsKey($d.Zone)) { $devByZone[$d.Zone] = @() }
        $devByZone[$d.Zone] += $d
    }
    $model | Add-Member -NotePropertyName DevicesByZone -NotePropertyValue $devByZone

    $model
}

function Expand-TiaSheetPattern {
    <#
    .SYNOPSIS
        Expand a naming pattern from 10_Project. Placeholders: {Zone} {DeviceRef}
        {Component} {Signal} {Layer} {Instruction} {Instance}.
    #>
    param([Parameter(Mandatory)][string]$Pattern, [hashtable]$Values)
    $s = $Pattern
    foreach ($k in $Values.Keys) { $s = $s -replace ('\{' + [regex]::Escape($k) + '\}'), [string]$Values[$k] }
    # collapse artefacts from empty placeholders
    ($s -replace '_{2,}', '_').Trim('_')
}

function Get-TiaSheetZoneChannels {
    <#
    .SYNOPSIS
        All safety (non-Diag) channels of a zone, with device context attached.
    #>
    param($Model, [string]$Zone)
    $out = @()
    foreach ($d in @($Model.DevicesByZone[$Zone])) {
        foreach ($c in @($Model.ChannelsByDevice[$d.DeviceID])) {
            if ($c.Signal -eq 'Diag') { continue }
            $out += [pscustomobject]@{
                Channel = $c; Device = $d
                TagName = Expand-TiaSheetPattern -Pattern $Model.Project['TagPattern'] -Values @{
                    Zone = $Zone; DeviceRef = $d.DeviceRef; Component = $c.Component; Signal = $c.Signal }
                MemberPath = "$($d.DeviceRef).$($c.Component).$($c.Signal)"
            }
        }
    }
    $out
}
