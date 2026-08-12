# Design-sheet ingestion + validation.
# Schema contract: docs/DESIGN-SHEET.md
#
# Sync-TiaDesignSheet is the ONLY networked cmdlet in this module. It is an explicit,
# on-demand sync into a COMMITTED CSV snapshot - never a build-time dependency, so the
# build stays reproducible from a git checkout and CI stays offline.

$script:TiaSheetSchemaVersion = '1.0'

# tab -> required columns (exact casing). Consumers do case-sensitive property access.
$script:TiaSheetSchema = [ordered]@{
    '10_Project'     = @('Key','Value','Notes')
    '20_Zones'       = @('Zone','Name','Description','Station','StationLabel','IM_MLFB','IM_FW','IOSystem','Verified','Notes')
    '21_Modules'     = @('Zone','Slot','Kind','MLFB','FW','ModuleName','InputBytes','AsBuiltRail','DrawingRef','Verified','Comment')
    '22_Devices'     = @('DeviceID','Zone','DeviceRef','DeviceType','UDT','Description','Location','DrawingRef','InInterlock','SF_ID','Verified','Notes')
    '23_Channels'    = @('ChannelID','DeviceID','Component','Signal','Paired','Polarity','AsBuiltSlot','AsBuiltChannel','AsBuiltTerminal','AsBuiltTagName','DesignSlot','DesignChannel','ModuleName','DrawingRef','Description','Verified')
    '30_UDTs'        = @('UDT','Order','Member','Datatype','Comment','FailsafeCompliant')
    '32_Blocks'      = @('Block','Zone','Layer','Language','Number','Description')
    '33_SafetyBlocks'= @('RowID','DeviceID','Component','Instruction','Version','InstanceName','DISCTIME','TIME_DEL','ACK_NEC','OPEN_NEC','AckSource','QTarget','Verified','Notes')
    '34_Interlocks'  = @('Zone','Target','DeviceID','Member','Include','Rationale','SF_ID')
}
# closed enum sets: "Tab.Column" -> allowed values
$script:TiaSheetEnums = @{
    '21_Modules.Kind'            = @('IM','F-DI','F-DQ','F-RQ','DI','DQ')
    '23_Channels.Signal'         = @('ChA','ChB','Diag')
    '23_Channels.Paired'         = @('Yes','No')
    '23_Channels.Polarity'       = @('NC','NO')
    '22_Devices.InInterlock'     = @('Yes','No')
    '32_Blocks.Layer'            = @('IOMap','Safety','Certified','Runtime','Data')
    '32_Blocks.Language'         = @('F_LAD','F_DB','F_FBD','LAD','SCL')
    '33_SafetyBlocks.Instruction'= @('ESTOP1','SFDOOR','EV1oo2DI','FDBACK','ACK_GL')
    '34_Interlocks.Target'       = @('Interlocks_OK','Zone_Safe')
    '34_Interlocks.Include'      = @('Yes','No')
}
$script:TiaSheetVerifiedCols = @('20_Zones','21_Modules','22_Devices','23_Channels','33_SafetyBlocks')

# Headers for every known tab, including the optional/governance ones. Used to preserve a
# tab's header when it legitimately has zero data rows (the xlsx reader consumes row 1 as
# the header, so an empty tab would otherwise lose its schema on sync).
$script:TiaSheetKnownHeaders = [ordered]@{
    '01_Revisions' = @('Rev','Date','Author','Summary','Approver','SnapshotCommit')
    '02_Decisions' = @('DecID','Topic','Question','Decision','Rationale','Status','Owner','Date')
    '35_Outputs'   = @('OutputID','Zone','DeviceID','Signal','Slot','Channel','DrivenBy','FDBACK')
}
foreach ($k in $script:TiaSheetSchema.Keys) { $script:TiaSheetKnownHeaders[$k] = $script:TiaSheetSchema[$k] }

function Sync-TiaDesignSheet {
    <#
    .SYNOPSIS
        Fetch a Google Sheet's tabs into a committed CSV snapshot (design/csv).
    .DESCRIPTION
        Reads design/sheet.json (sheetId, transport, tabs: name -> gid) and writes one
        deterministic CSV per tab plus .sheet-sync.json (timestamp, per-tab rows + sha256).
        Fails loudly when a response is HTML (an unpublished or permission-denied sheet
        returns a login page, which would otherwise land on disk as a "valid" CSV).
    .PARAMETER Path
        Project design folder holding sheet.json (default: .\design).
    .PARAMETER DiffOnly
        Fetch and report what would change; write nothing.
    .PARAMETER ApiKey
        Google API key (transport 'api-key'). Keep it in the PRIVATE project repo.
    .EXAMPLE
        Sync-TiaDesignSheet -Path .\design
        Sync-TiaDesignSheet -Path .\design -DiffOnly
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '.\design',
        [switch]$DiffOnly,
        [string]$ApiKey
    )
    # .NET file APIs use the PROCESS working directory, which Set-Location does not
    # change - resolve to an absolute path up front or writes land in the wrong root.
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $cfgPath = Join-Path $Path 'sheet.json'
    if (-not (Test-Path $cfgPath)) { throw "No sheet.json at $cfgPath (see engine docs/DESIGN-SHEET.md)." }
    $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
    if (-not $cfg.sheetId) { throw "sheet.json has no sheetId." }
    if ($cfg.schemaVersion -and ([version]$cfg.schemaVersion -gt [version]$script:TiaSheetSchemaVersion)) {
        throw "Sheet schemaVersion $($cfg.schemaVersion) is newer than this engine supports ($script:TiaSheetSchemaVersion)."
    }
    $transport = if ($cfg.transport) { $cfg.transport } else { 'published-csv' }
    $outDir = Join-Path $Path 'csv'
    if (-not $DiffOnly) { New-Item -ItemType Directory -Force $outDir | Out-Null }

    # TLS 1.2 - PS 5.1 defaults to SSL3/TLS1 which Google refuses
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $changed = @(); $same = @(); $state = [ordered]@{}

    # 'xlsx-export' fetches the WHOLE workbook once and reads tabs by name - no gids to
    # maintain, and it works with plain link-sharing (no publish-to-web).
    $book = $null; $bookTabs = $null
    if ($transport -eq 'xlsx-export') {
        $book = Join-Path ([IO.Path]::GetTempPath()) ("tia-sheet-" + [guid]::NewGuid().ToString('n') + ".xlsx")
        $url = "https://docs.google.com/spreadsheets/d/$($cfg.sheetId)/export?format=xlsx"
        Write-Verbose "GET $url"
        try { Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $book -ErrorAction Stop }
        catch { throw "Workbook fetch failed: $($_.Exception.Message)" }
        $magic = [System.IO.File]::ReadAllBytes($book)[0..1]
        if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) {
            Remove-Item $book -Force -ErrorAction SilentlyContinue
            throw ("Workbook fetch returned HTML, not xlsx - the sheet is not readable by " +
                   "link. Share it (Anyone with the link -> Viewer) or use transport 'api-key'.")
        }
        $bookTabs = Get-TiaXlsxSheetName -Path $book
        Write-Verbose ("workbook tabs: " + ($bookTabs -join ', '))
    }

    # tab list: sheet.json when populated, else whatever the workbook contains
    $tabList = @()
    if ($cfg.tabs) { $tabList = @($cfg.tabs.PSObject.Properties) }
    if ($transport -eq 'xlsx-export' -and (-not $tabList -or -not $tabList.Count)) {
        $tabList = @($bookTabs | ForEach-Object { [pscustomobject]@{ Name = $_; Value = '' } })
    }

    foreach ($tab in $tabList) {
        $name = $tab.Name; $gid = [string]$tab.Value
        if ($transport -eq 'xlsx-export') {
            if ($bookTabs -notcontains $name) {
                Write-Host ("  {0,-18} MISSING in the sheet - skipped" -f $name) -ForegroundColor Yellow
                continue
            }
            $rows = @(Import-TiaXlsx -Path $book -Sheet $name)
            $cols = if ($rows.Count) { $rows[0].PSObject.Properties.Name }
                    elseif ($script:TiaSheetKnownHeaders.Contains($name)) { $script:TiaSheetKnownHeaders[$name] }
                    else { @() }
            $vals = @(, $cols)
            foreach ($r in $rows) { $vals += , @($cols | ForEach-Object { [string]$r.$_ }) }
            $text = (ConvertTo-TiaCsvText -Values $vals)
            $text = ($text -replace "`r`n", "`n").TrimEnd("`n")
            $target = Join-Path $outDir "$name.csv"
            $old = if (Test-Path $target) { ((Get-Content -Raw $target) -replace "`r`n","`n").TrimEnd("`n") } else { $null }
            if ($old -ne $text) { $changed += $name } else { $same += $name }
            if (-not $DiffOnly) {
                try { [System.IO.File]::WriteAllText($target, $text + "`n", (New-Object System.Text.UTF8Encoding($false))) }
                catch { throw "Failed writing snapshot '$target': $($_.Exception.Message)" }
            }
            $sha = (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text)))).Hash
            $state[$name] = [ordered]@{ rows = $rows.Count; sha256 = $sha }
            Write-Host ("  {0,-18} {1,4} rows {2}" -f $name, $rows.Count,
                        $(if ($changed -contains $name) { 'CHANGED' } else { 'unchanged' }))
            continue
        }
        switch ($transport) {
            'api-key' {
                if (-not $ApiKey) { $ApiKey = $cfg.apiKey }
                if (-not $ApiKey) { throw "transport 'api-key' needs -ApiKey (or apiKey in sheet.json)." }
                $url = "https://sheets.googleapis.com/v4/spreadsheets/$($cfg.sheetId)/values/$([uri]::EscapeDataString($name))?key=$ApiKey"
            }
            default {
                $url = "https://docs.google.com/spreadsheets/d/$($cfg.sheetId)/export?format=csv&gid=$gid"
            }
        }
        Write-Verbose "GET $url"
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        } catch {
            throw "Fetch failed for tab '$name': $($_.Exception.Message)"
        }
        $text = $resp.Content
        if ($transport -eq 'api-key') {
            $json = $text | ConvertFrom-Json
            $text = (ConvertTo-TiaCsvText -Values $json.values)
        } else {
            # an unpublished sheet returns an HTML sign-in page with HTTP 200
            $head = $text.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
            if ($head -match '^\s*<(!DOCTYPE|html)' -or $resp.Headers['Content-Type'] -match 'text/html') {
                throw ("Tab '$name' returned HTML, not CSV - the sheet is not published or not " +
                       "readable. Publish it (File > Share > Publish to web) or use transport 'api-key'.")
            }
        }
        $text = ($text -replace "`r`n", "`n").TrimEnd("`n")
        $lines = @($text -split "`n")
        $target = Join-Path $outDir "$name.csv"
        $old = if (Test-Path $target) { ((Get-Content -Raw $target) -replace "`r`n","`n").TrimEnd("`n") } else { $null }
        if ($old -ne $text) { $changed += $name } else { $same += $name }
        if (-not $DiffOnly) {
            [System.IO.File]::WriteAllText($target, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
        }
        $sha = (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text)))).Hash
        $state[$name] = [ordered]@{ rows = [Math]::Max(0, $lines.Count - 1); sha256 = $sha }
        Write-Host ("  {0,-18} {1,4} rows {2}" -f $name, [Math]::Max(0,$lines.Count-1),
                    $(if ($changed -contains $name) { 'CHANGED' } else { 'unchanged' }))
    }

    if ($book -and (Test-Path $book)) { Remove-Item $book -Force -ErrorAction SilentlyContinue }

    if (-not $DiffOnly) {
        $meta = [ordered]@{
            syncedUtc     = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
            sheetId       = $cfg.sheetId
            schemaVersion = $script:TiaSheetSchemaVersion
            transport     = $transport
            tabs          = $state
        }
        $meta | ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII (Join-Path $Path '.sheet-sync.json')
    }
    [pscustomobject]@{
        Ok = $true; Changed = $changed; Unchanged = $same; DiffOnly = [bool]$DiffOnly; OutDir = $outDir
    }
}

function Test-TiaDesignSheet {
    <#
    .SYNOPSIS
        Validate a design-sheet CSV snapshot offline (schema + referential + safety rules).
    .DESCRIPTION
        Implements the rules in engine docs/DESIGN-SHEET.md. No TIA and no network needed,
        so it runs in CI. Returns { Ok, Errors, Warnings, Summary }.
    .PARAMETER Path
        Folder of <TabName>.csv (e.g. .\design\csv or .\design\seed).
    .PARAMETER RequireVerified
        Treat Verified=No rows as errors (use before generating certified safety logic).
    .EXAMPLE
        Test-TiaDesignSheet -Path .\design\csv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequireVerified
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $warns  = New-Object System.Collections.Generic.List[string]
    $tabs = @{}

    foreach ($t in $script:TiaSheetSchema.Keys) {
        $f = Join-Path $Path "$t.csv"
        if (-not (Test-Path $f)) { $errors.Add("missing tab: $t.csv"); continue }
        $rows = @(Import-Csv $f)
        $tabs[$t] = $rows
        $have = @()
        if ($rows.Count) { $have = $rows[0].PSObject.Properties.Name }
        else { $have = (Get-Content -TotalCount 1 $f) -split ',' | ForEach-Object { $_.Trim('"') } }
        foreach ($c in $script:TiaSheetSchema[$t]) {
            if ($have -cnotcontains $c) { $errors.Add("${t}: missing column '$c' (exact casing required)") }
        }
    }
    if ($errors.Count) {
        return [pscustomobject]@{ Ok=$false; Errors=$errors; Warnings=$warns; Summary='schema failed' }
    }

    foreach ($k in $script:TiaSheetEnums.Keys) {
        $t, $c = $k -split '\.', 2
        if (-not $tabs.ContainsKey($t)) { continue }
        $allowed = $script:TiaSheetEnums[$k]
        $n = 0
        foreach ($r in $tabs[$t]) {
            $n++
            $v = [string]$r.$c
            if ([string]::IsNullOrWhiteSpace($v)) { $errors.Add("${t} row ${n}: '$c' is blank (enum)"); continue }
            if ($allowed -cnotcontains $v) { $errors.Add("${t} row ${n}: '$c'='$v' not in {$($allowed -join ', ')}") }
        }
    }

    # project keys - these drive project creation, so missing ones are hard errors
    $proj = @{}
    foreach ($r in $tabs['10_Project']) { if ($r.Key) { $proj[$r.Key] = [string]$r.Value } }
    foreach ($k in @('ProjectName','PlcName','CpuMLFB','CpuFW','SubnetName','IoSystemName',
                     'SafetyRuntimeFB','TagTableIn','TagPattern','DbPattern','BlockPattern',
                     'InstancePattern','BlockNumberBase','BlockNumberStep','DefaultPolarity')) {
        if (-not $proj.ContainsKey($k) -or -not $proj[$k]) { $errors.Add("10_Project: missing key '$k'") }
    }
    if ($proj['SchemaVersion'] -and ([version]$proj['SchemaVersion'] -gt [version]$script:TiaSheetSchemaVersion)) {
        $errors.Add("10_Project: SchemaVersion $($proj['SchemaVersion']) is newer than this engine supports ($script:TiaSheetSchemaVersion)")
    }
    if ($proj['DefaultPolarity'] -and @('NC','NO') -cnotcontains $proj['DefaultPolarity']) {
        $errors.Add("10_Project: DefaultPolarity '$($proj['DefaultPolarity'])' must be NC or NO")
    }

    $zones   = @{}; foreach ($r in $tabs['20_Zones'])  { $zones[$r.Zone] = $r }
    $devices = @{}; foreach ($r in $tabs['22_Devices']){ $devices[$r.DeviceID] = $r }
    $udts    = @{}; foreach ($r in $tabs['30_UDTs'])   { $udts[$r.UDT] = $true }
    $mods    = @{}; foreach ($r in $tabs['21_Modules']){ $mods["$($r.Zone)/$($r.ModuleName)"] = $r }

    foreach ($r in $tabs['22_Devices']) {
        if (-not $zones.ContainsKey($r.Zone)) { $errors.Add("22_Devices $($r.DeviceID): unknown Zone '$($r.Zone)'") }
        if ($r.UDT -and -not $udts.ContainsKey($r.UDT)) { $errors.Add("22_Devices $($r.DeviceID): UDT '$($r.UDT)' not in 30_UDTs") }
    }
    foreach ($r in $tabs['21_Modules']) {
        if (-not $zones.ContainsKey($r.Zone)) { $errors.Add("21_Modules $($r.ModuleName): unknown Zone '$($r.Zone)'") }
        $slot = 0
        if (-not [int]::TryParse([string]$r.Slot, [ref]$slot)) { $errors.Add("21_Modules $($r.ModuleName): Slot '$($r.Slot)' is not an integer") }
    }

    # channels: referential + safety
    $chanUse = @{}; $group = @{}
    foreach ($r in $tabs['23_Channels']) {
        $id = $r.ChannelID
        if (-not $devices.ContainsKey($r.DeviceID)) { $errors.Add("23_Channels ${id}: unknown DeviceID '$($r.DeviceID)'"); continue }
        $z = $devices[$r.DeviceID].Zone
        if ($r.ModuleName -and -not $mods.ContainsKey("$z/$($r.ModuleName)")) {
            $errors.Add("23_Channels ${id}: ModuleName '$($r.ModuleName)' not a module of zone $z")
        }
        if ($r.Signal -ne 'Diag') {
            if ("$($r.DesignSlot)$($r.DesignChannel)" -eq '') {
                $errors.Add("23_Channels ${id}: DesignSlot/DesignChannel required for a safety signal")
            } else {
                $key = "$z/$($r.DesignSlot)/$($r.DesignChannel)"
                if ($chanUse.ContainsKey($key)) { $errors.Add("23_Channels ${id}: design channel $key already used by $($chanUse[$key])") }
                else { $chanUse[$key] = $id }
            }
            $g = "$($r.DeviceID)|$($r.Component)"
            if (-not $group.ContainsKey($g)) { $group[$g] = @{ Paired = $r.Paired; Sigs = @() } }
            $group[$g].Sigs += $r.Signal
            if ($group[$g].Paired -ne $r.Paired) { $errors.Add("23_Channels ${id}: inconsistent Paired within $g") }
        }
        if ($r.AsBuiltSlot -ne $r.DesignSlot -or $r.AsBuiltChannel -ne $r.DesignChannel) {
            $warns.Add("23_Channels ${id}: as-built s$($r.AsBuiltSlot)/ch$($r.AsBuiltChannel) -> design s$($r.DesignSlot)/ch$($r.DesignChannel) is a WIRING CHANGE (safety review)")
        }
    }
    foreach ($g in $group.Keys) {
        $sigs = @($group[$g].Sigs | Sort-Object)
        if ($group[$g].Paired -eq 'Yes') {
            if (($sigs -join ',') -ne 'ChA,ChB') { $errors.Add("23_Channels ${g}: Paired=Yes needs exactly one ChA and one ChB (got $($sigs -join ','))") }
        } else {
            if (($sigs -join ',') -ne 'ChA') { $errors.Add("23_Channels ${g}: Paired=No needs exactly one ChA (got $($sigs -join ','))") }
            else { $warns.Add("23_Channels ${g}: SINGLE-CHANNEL (1oo1) - normally unacceptable for a PPS trip; needs review") }
        }
    }

    # interlock coverage - a device wired and indicated but absent from the trip path
    # is worse than absent, because it looks functional
    $inter = @{}
    foreach ($r in $tabs['34_Interlocks']) {
        if (-not $devices.ContainsKey($r.DeviceID)) { $errors.Add("34_Interlocks: unknown DeviceID '$($r.DeviceID)'"); continue }
        if ($r.Include -eq 'Yes') { $inter[$r.DeviceID] = $true }
        elseif (-not $r.Rationale) { $errors.Add("34_Interlocks $($r.DeviceID): Include=No requires a Rationale") }
    }
    foreach ($d in $tabs['22_Devices']) {
        if ($d.InInterlock -eq 'Yes' -and -not $inter.ContainsKey($d.DeviceID)) {
            $errors.Add("34_Interlocks: device $($d.DeviceID) is InInterlock=Yes but not included in any interlock target")
        }
    }

    $chanGroups = @{}; foreach ($k in $group.Keys) { $chanGroups[$k] = $true }
    foreach ($r in $tabs['33_SafetyBlocks']) {
        if (-not $devices.ContainsKey($r.DeviceID)) { $errors.Add("33_SafetyBlocks $($r.RowID): unknown DeviceID '$($r.DeviceID)'"); continue }
        if (-not $chanGroups.ContainsKey("$($r.DeviceID)|$($r.Component)")) {
            $errors.Add("33_SafetyBlocks $($r.RowID): no channels for $($r.DeviceID).$($r.Component)")
        }
        foreach ($tp in @('DISCTIME','TIME_DEL')) {
            $v = [string]$r.$tp
            if ($v -and $v -notmatch '^(?i)T#') { $errors.Add("33_SafetyBlocks $($r.RowID): $tp '$v' is not IEC time (T#500ms)") }
        }
        if ($r.Instruction -eq 'EV1oo2DI' -and -not $r.DISCTIME) {
            $warns.Add("33_SafetyBlocks $($r.RowID): EV1oo2DI without DISCTIME - discrepancy time is a safety parameter")
        }
    }

    $unver = 0
    foreach ($t in $script:TiaSheetVerifiedCols) {
        foreach ($r in $tabs[$t]) { if ($r.Verified -ne 'Yes') { $unver++ } }
    }
    if ($unver) {
        $msg = "$unver row(s) are Verified<>Yes - unconfirmed against drawings"
        if ($RequireVerified) { $errors.Add($msg) } else { $warns.Add($msg) }
    }

    $summary = ("{0} zones, {1} modules, {2} devices, {3} channels, {4} safety blocks, {5} unverified" -f
        $tabs['20_Zones'].Count, $tabs['21_Modules'].Count, $tabs['22_Devices'].Count,
        $tabs['23_Channels'].Count, $tabs['33_SafetyBlocks'].Count, $unver)
    [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors; Warnings = $warns; Summary = $summary }
}
