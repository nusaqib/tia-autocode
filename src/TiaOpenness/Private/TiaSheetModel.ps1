# Read a design-sheet CSV snapshot into a structured model.
# Schema contract: docs/DESIGN-SHEET.md. Consumed by Invoke-TiaBuildFromSheet.

function Get-TiaXlsxSheetName {
    <#
    .SYNOPSIS
        Tab names of an .xlsx, in workbook order (dependency-free: zip + xl/workbook.xml).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $zip = Open-TiaXlsxArchive -Path $Path
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
        Load design/csv into a model: Project, Areas, Modules, Devices, Channels, Udts,
        Blocks, SafetyBlocks, Interlocks - with per-area indexes the builder needs.
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
        Stations     = T '20_Stations'
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

    $modByArea = @{}
    foreach ($x in $model.Modules) {
        if (-not $modByArea.ContainsKey($x.Area)) { $modByArea[$x.Area] = @() }
        $modByArea[$x.Area] += $x
    }
    $model | Add-Member -NotePropertyName ModulesByArea -NotePropertyValue $modByArea

    $devByArea = @{}
    foreach ($d in $model.Devices) {
        if (-not $devByArea.ContainsKey($d.Area)) { $devByArea[$d.Area] = @() }
        $devByArea[$d.Area] += $d
    }
    $model | Add-Member -NotePropertyName DevicesByArea -NotePropertyValue $devByArea

    $model
}

function Expand-TiaSheetPattern {
    <#
    .SYNOPSIS
        Expand a naming pattern from 10_Project. Placeholders: {Area} {DeviceRef}
        {Component} {Signal} {Layer} {Instruction} {Instance}.
    #>
    param([Parameter(Mandatory)][string]$Pattern, [hashtable]$Values)
    $s = $Pattern
    foreach ($k in $Values.Keys) { $s = $s -replace ('\{' + [regex]::Escape($k) + '\}'), [string]$Values[$k] }
    # collapse artefacts from empty placeholders
    ($s -replace '_{2,}', '_').Trim('_')
}

function Resolve-TiaProjectPath {
    <#
    .SYNOPSIS
        Absolute output-project path for a design snapshot.
    .DESCRIPTION
        Precedence: an explicit -ProjectPath, then 10_Project's ProjectPath, then
        <repo>\_out\<ProjectName>. A RELATIVE value is resolved against the design repo
        root, never against the caller's current directory - the sheet says where a project
        goes relative to its own repo, and a build must land in the same place whatever
        directory it was launched from.
    #>
    param([string]$ProjectPath, [Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$RepoRoot)
    $p = $ProjectPath
    if (-not $p) { $p = [string]$Project['ProjectPath'] }
    if (-not $p) { $p = Join-Path '_out' ([string]$Project['ProjectName']) }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $RepoRoot $p }
    [System.IO.Path]::GetFullPath($p)
}

function Get-TiaModuleKindToken {
    <#
    .SYNOPSIS
        21_Modules.Kind as a name token: 'F-DI' -> 'FDI'.
    .DESCRIPTION
        The Kind enum is the catalogue spelling ('F-DI'); a hyphen is not legal in a TIA
        object name, so ModulePattern gets the stripped form.
    #>
    param([string]$Kind)
    ([string]$Kind) -replace '[^A-Za-z0-9]', ''
}

function Get-TiaSheetAreaChannels {
    <#
    .SYNOPSIS
        All safety (non-Diag) channels of an area, with device context attached.
    #>
    param($Model, [string]$Area)
    $out = @()
    foreach ($d in @($Model.DevicesByArea[$Area])) {
        foreach ($c in @($Model.ChannelsByDevice[$d.DeviceID])) {
            if ($c.Signal -eq 'Diag') { continue }
            $out += [pscustomobject]@{
                Channel = $c; Device = $d
                TagName = Expand-TiaSheetPattern -Pattern $Model.Project['TagPattern'] -Values @{
                    Area = $Area; DeviceRef = $d.DeviceRef; Component = $c.Component; Signal = $c.Signal }
                MemberPath = "$($d.DeviceRef).$($c.Component).$($c.Signal)"
            }
        }
    }
    $out
}
