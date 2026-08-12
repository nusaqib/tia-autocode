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

function Expand-TiaSheetInterlockMatrix {
    <#
    .SYNOPSIS
        Expand the 34_Interlocks checkmark grid into one row per contributor.
    .DESCRIPTION
        34_Interlocks is authored as a cause-and-effect matrix: one row per (Area, Target),
        one column per DeviceID, a mark where that device feeds that target. Everything
        downstream wants the long form, so the grid is expanded once - here - and neither
        the validator nor the build ever sees the matrix shape.

        A cell is a mark or it is empty. Anything else comes back as a fault rather than a
        guess: an unreadable cell must never quietly resolve to "not in the trip path",
        which is the one failure mode a coverage matrix exists to prevent.
    .OUTPUTS
        Rows (Area, Target, DeviceID, Include='Yes'), Columns (the device columns, in
        sheet order), Errors (unreadable cells).
    #>
    param([AllowEmptyCollection()][object[]]$Rows)

    $marks = @('X', 'YES', 'Y', '1', 'TRUE')
    $fixed = @('Area', 'Target')
    $out = @(); $bad = @(); $cols = @()
    if ($Rows -and $Rows.Count) {
        $cols = @($Rows[0].PSObject.Properties.Name | Where-Object { $fixed -notcontains $_ })
    }
    $n = 0
    foreach ($r in $Rows) {
        $n++
        if (-not $r) { continue }
        foreach ($c in $cols) {
            $v = ([string]$r.$c).Trim()
            if (-not $v) { continue }
            if ($marks -contains $v.ToUpperInvariant()) {
                $out += [pscustomobject]@{
                    Area   = [string]$r.Area; Target = [string]$r.Target
                    DeviceID = $c; Include = 'Yes'; Row = $n
                }
            } else {
                $bad += ("34_Interlocks row ${n} ($($r.Area) $($r.Target)): cell under '$c' is " +
                         "'$v' - a cell is a mark (X) or empty, nothing else")
            }
        }
    }
    [pscustomobject]@{ Rows = $out; Columns = $cols; Errors = $bad }
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
        Exclusions   = T '34_Exclusions'
        Outputs      = T '35_Outputs'
    }
    $model = [pscustomobject]$m

    # The interlock grid is an authoring shape, not a build shape. Expand it here so the
    # phases keep consuming one row per contributor and never learn about columns.
    $mx = Expand-TiaSheetInterlockMatrix -Rows $model.Interlocks
    if ($mx.Errors.Count) { throw ($mx.Errors -join "`n") }
    $model.Interlocks = $mx.Rows

    # A device IS a member of its area's UDT. Once 30_UDTs declares those areas explicitly
    # there is nothing left for 22_Devices to say that the UDT row does not, so the device
    # list is synthesised from it and the tab is gone. DeviceID stays as the key channels
    # and interlocks join on, and is exactly "{Area}_{Member}" - the validator enforces that
    # rather than leaving it as a convention someone has to know.
    if (-not $model.Devices.Count -and $model.Udts.Count) {
        $pattern = $proj['AreaUdtPattern']
        if (-not $pattern) { $pattern = 'UDT_Area_{Area}' }
        $like = $pattern -replace '\{Area\}', '*'
        # longest-match area name, so S01_FE never resolves as S01
        $areaNames = @($model.Stations | ForEach-Object { [string]$_.Area } |
                       Sort-Object { $_.Length } -Descending)
        $scalars = @('Area_Reset', 'Interlocks_OK', 'Area_Safe')
        $synth = @()
        foreach ($u in $model.Udts) {
            if ($u.UDT -notlike $like) { continue }
            if ($scalars -contains $u.Member) { continue }
            $area = $areaNames | Where-Object { $u.UDT -eq ($pattern -replace '\{Area\}', $_) } | Select-Object -First 1
            if (-not $area) { continue }
            $synth += [pscustomobject]@{
                DeviceID = "${area}_$($u.Member)"; Area = $area; Device = $u.Member
                UDT = ([string]$u.Datatype).Trim().Trim('"'); Description = $u.Comment
                Location = ''; DrawingRef = ''; InInterlock = 'Yes'; SF_ID = ''
                Verified = ''; Notes = ''
            }
        }
        $model.Devices = $synth
    }

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
        Expand a naming pattern from 10_Project. Placeholders: {Area} {Device}
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

function Get-TiaModuleInputType {
    <#
    .SYNOPSIS
        Tag-name safety-class prefix for a channel, from its module Kind.
    .DESCRIPTION
        fi = fail-safe input, fo = fail-safe output, ni / no = the standard equivalents.
        The prefix is DERIVED, never authored: it restates the module the channel is wired
        to, and a hand-typed prefix that disagrees with the rack would be a tag that lies
        about its own safety class.
    #>
    param([string]$Kind)
    switch (([string]$Kind).ToUpperInvariant()) {
        'F-DI' { 'fi' }
        'F-DQ' { 'fo' }
        'F-RQ' { 'fo' }
        'DI'   { 'ni' }
        'DQ'   { 'no' }
        default { '' }
    }
}

function Get-TiaSheetAreaChannels {
    <#
    .SYNOPSIS
        All safety (non-Diag) channels of an area, with device context attached.
    #>
    param($Model, [string]$Area)
    $out = @()
    foreach ($d in @($Model.DevicesByArea[$Area] | Where-Object { $_ })) {
        foreach ($c in @($Model.ChannelsByDevice[$d.DeviceID])) {
            if ($c.Signal -eq 'Diag') { continue }
            $out += [pscustomobject]@{
                Channel = $c; Device = $d
                TagName = Expand-TiaSheetPattern -Pattern $Model.Project['TagPattern'] -Values @{
                    Area = $Area; Device = $d.Device; Component = $c.Component; Signal = $c.Signal }
                MemberPath = "$($d.Device).$($c.Component).$($c.Signal)"
            }
        }
    }
    $out
}
