# Design-sheet ingestion + validation.
# Schema contract: docs/DESIGN-SHEET.md
#
# Sync-TiaDesignSheet is the ONLY networked cmdlet in this module. It is an explicit,
# on-demand sync into a COMMITTED CSV snapshot - never a build-time dependency, so the
# build stays reproducible from a git checkout and CI stays offline.

$script:TiaSheetSchemaVersion = '1.2'

# tab -> required columns (exact casing). Consumers do case-sensitive property access.
#
# v1.1 changes (see docs/DESIGN-SHEET.md "Schema history"):
#   - 23_Channels: DesignSlot/DesignChannel REMOVED. They existed only to express the
#     in-module re-map that FIRMWARE 1oo2 requires (ChA/ChB on channel n and n+4 of one
#     module). Project decision D01 evaluates 1oo2 in SOFTWARE (EV1oo2DI), so the as-built
#     wiring is the only wiring - and ChA/ChB on separate modules is the safer arrangement.
#     AsBuilt* prefixes dropped with them: there is now one wiring truth, so Slot/Channel
#     need no qualifier.
#   - 21_Modules: F-parameters added. F_DestAddr (PROFIsafe destination address) must be
#     unique per network and is a reviewable safety parameter; Openness cannot set the
#     F-DI sensor evaluation, so SensorEval records the INTENDED value for the manual TIA
#     step and lets a report check it.
#   - 31_Policy added: DeviceType+Component -> certified instruction chain, declared ONCE.
#     Previously every device carried its own 33_SafetyBlocks row (131 rows mechanically
#     derived from DeviceType) - 131 chances to drift from a 10-line rule.
#   - 33_SafetyBlocks is now an OVERRIDE tab: only rows that deviate from 31_Policy.
#
# v1.2 changes:
#   - 20_Zones RENAMED to 20_Stations. Each row is one ET200SP station on the PROFINET IO
#     system, and calling it a "Device" tab would collide with 22_Devices (field devices) -
#     two different meanings for DeviceID/DeviceRef in a safety review.
#   - 20_Stations gains IpAddress / SubnetMask / DeviceNumber / DeviceName. These were
#     auto-assigned by TIA and recorded nowhere, so they were neither reviewable nor stable
#     across rebuilds. Blank still means "let TIA assign".
$script:TiaSheetSchema = [ordered]@{
    '10_Project'     = @('Key','Value','Notes')
    '20_Stations'    = @('Zone','Name','Description','Station','StationLabel','IM_MLFB','IM_FW','IOSystem','IpAddress','SubnetMask','DeviceNumber','DeviceName','Verified','Notes')
    '21_Modules'     = @('Zone','Slot','Kind','MLFB','FW','ModuleName','InputBytes','F_DestAddr','F_MonitorTime','SensorEval','AsBuiltRail','DrawingRef','Verified','Comment')
    '22_Devices'     = @('DeviceID','Zone','DeviceRef','DeviceType','UDT','Description','Location','DrawingRef','InInterlock','SF_ID','Verified','Notes')
    '23_Channels'    = @('ChannelID','DeviceID','Component','Signal','Paired','Polarity','Slot','Channel','Terminal','LegacyTagName','ModuleName','DrawingRef','Description','Verified')
    '30_UDTs'        = @('UDT','Order','Member','Datatype','Comment','FailsafeCompliant')
    '31_Policy'      = @('PolicyID','DeviceType','Component','UDT','Order','Instruction','Version','DISCTIME','TIME_DEL','ACK_NEC','OPEN_NEC','AckSource','QTarget','Rationale','Verified')
    '32_Blocks'      = @('Block','Zone','Layer','Language','Number','Description')
    '33_SafetyBlocks'= @('RowID','DeviceID','Component','Instruction','Version','InstanceName','DISCTIME','TIME_DEL','ACK_NEC','OPEN_NEC','AckSource','QTarget','Verified','Notes')
    '34_Interlocks'  = @('Zone','Target','DeviceID','Member','Include','Rationale','SF_ID')
}
# closed enum sets: "Tab.Column" -> allowed values
$script:TiaSheetEnums = @{
    '21_Modules.Kind'            = @('IM','F-DI','F-DQ','F-RQ','DI','DQ')
    '21_Modules.SensorEval'      = @('1oo1','1oo2')
    '23_Channels.Signal'         = @('ChA','ChB','Diag')
    '23_Channels.Paired'         = @('Yes','No')
    '23_Channels.Polarity'       = @('NC','NO')
    '22_Devices.InInterlock'     = @('Yes','No')
    '31_Policy.Instruction'      = @('ESTOP1','SFDOOR','EV1oo2DI','FDBACK','ACK_GL')
    '32_Blocks.Layer'            = @('IOMap','Safety','Certified','Runtime','Data')
    '32_Blocks.Language'         = @('F_LAD','F_DB','F_FBD','LAD','SCL')
    '33_SafetyBlocks.Instruction'= @('ESTOP1','SFDOOR','EV1oo2DI','FDBACK','ACK_GL')
    '34_Interlocks.Target'       = @('Interlocks_OK','Zone_Safe')
    '34_Interlocks.Include'      = @('Yes','No')
}
$script:TiaSheetVerifiedCols = @('20_Stations','21_Modules','22_Devices','23_Channels','31_Policy','33_SafetyBlocks')

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
        Expand a design workbook's tabs into a committed CSV snapshot (design/csv).
    .DESCRIPTION
        The workbook is the authoring surface; the CSV snapshot is the build input. They
        are kept separate on purpose: an .xlsx is a binary blob, so 'git diff' on it says
        nothing, and for a safety design the per-cell change record IS the review evidence.

        Transports (design/sheet.json "transport"):
          workbook      local .xlsx in the project repo - no network, no credentials.
          xlsx-export   Google Sheets whole-workbook export (plain link-sharing is enough).
          published-csv per-tab gid CSV export (needs File > Share > Publish to web).
          api-key       Google Sheets API with a key kept in the PRIVATE project repo.

        Writes one deterministic CSV per tab plus .sheet-sync.json (per-tab rows + sha256).
        Network transports fail loudly when a response is HTML - an unpublished or
        permission-denied sheet returns a login page, which would otherwise land on disk
        as a perfectly "valid" CSV.
    .PARAMETER Path
        Project design folder holding sheet.json (default: .\design).
    .PARAMETER Workbook
        Local .xlsx to read, overriding sheet.json. Implies transport 'workbook'.
    .PARAMETER DiffOnly
        Report what would change; write nothing.
    .PARAMETER ApiKey
        Google API key (transport 'api-key'). Keep it in the PRIVATE project repo.
    .EXAMPLE
        Sync-TiaDesignSheet -Path .\design
        Sync-TiaDesignSheet -Path .\design -DiffOnly
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '.\design',
        [string]$Workbook,
        [switch]$DiffOnly,
        [switch]$Quiet,
        [string]$ApiKey
    )
    # .NET file APIs use the PROCESS working directory, which Set-Location does not
    # change - resolve to an absolute path up front or writes land in the wrong root.
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $cfgPath = Join-Path $Path 'sheet.json'
    $cfg = $null
    if (Test-Path $cfgPath) { $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json }

    # No config and no -Workbook: a single .xlsx in the design folder IS the design, so
    # the common case needs no config file at all. Two would be ambiguous - say so.
    if (-not $cfg -and -not $Workbook) {
        $found = @(Get-ChildItem -Path $Path -Filter '*.xlsx' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notlike '~$*' })
        if ($found.Count -eq 1) { $Workbook = $found[0].FullName }
        elseif ($found.Count -gt 1) {
            throw ("$Path holds $($found.Count) .xlsx files - name one with -Workbook, or add " +
                   "sheet.json: " + (($found | ForEach-Object { $_.Name }) -join ', '))
        }
        else { throw "No design workbook (.xlsx) and no sheet.json in $Path (see engine docs/DESIGN-SHEET.md)." }
    }

    $transport = if ($Workbook) { 'workbook' }
                 elseif ($cfg.transport) { $cfg.transport }
                 else { 'published-csv' }
    if ($cfg -and $cfg.schemaVersion -and ([version]$cfg.schemaVersion -gt [version]$script:TiaSheetSchemaVersion)) {
        throw "Sheet schemaVersion $($cfg.schemaVersion) is newer than this engine supports ($script:TiaSheetSchemaVersion)."
    }
    if ($transport -ne 'workbook' -and -not $cfg.sheetId) { throw "sheet.json has no sheetId." }
    $outDir = Join-Path $Path 'csv'
    if (-not $DiffOnly) { New-Item -ItemType Directory -Force $outDir | Out-Null }

    # TLS 1.2 - PS 5.1 defaults to SSL3/TLS1 which Google refuses
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $changed = @(); $same = @(); $state = [ordered]@{}

    # Whole-workbook transports read tabs by NAME - no gids to maintain. 'workbook' is a
    # local file (no network at all); 'xlsx-export' pulls the same shape from Google.
    $bookMode = @('workbook','xlsx-export') -contains $transport
    $book = $null; $bookTabs = $null; $tempBook = $false
    if ($transport -eq 'workbook') {
        if (-not $Workbook) { $Workbook = [string]$cfg.workbook }
        if (-not $Workbook) { throw "transport 'workbook' needs a 'workbook' entry in sheet.json (or -Workbook)." }
        $book = if ([IO.Path]::IsPathRooted($Workbook)) { $Workbook } else { Join-Path $Path $Workbook }
        if (-not (Test-Path $book)) { throw "Design workbook not found: $book" }
        $book = (Resolve-Path $book).ProviderPath
        $bookTabs = Get-TiaXlsxSheetName -Path $book
    }
    elseif ($transport -eq 'xlsx-export') {
        $tempBook = $true
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
    }
    if ($bookMode) { Write-Verbose ("workbook tabs: " + ($bookTabs -join ', ')) }

    # tab list: sheet.json when populated, else whatever the workbook contains
    $tabList = @()
    if ($cfg -and $cfg.tabs) { $tabList = @($cfg.tabs.PSObject.Properties) }
    if ($bookMode -and (-not $tabList -or -not $tabList.Count)) {
        $tabList = @($bookTabs | ForEach-Object { [pscustomobject]@{ Name = $_; Value = '' } })
    }

    foreach ($tab in $tabList) {
        $name = $tab.Name; $gid = [string]$tab.Value
        if ($bookMode) {
            if ($bookTabs -notcontains $name) {
                if (-not $Quiet) { Write-Host ("  {0,-18} MISSING in the sheet - skipped" -f $name) -ForegroundColor Yellow }
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
            if (-not $Quiet) {
                Write-Host ("  {0,-18} {1,4} rows {2}" -f $name, $rows.Count,
                            $(if ($changed -contains $name) { 'CHANGED' } else { 'unchanged' }))
            }
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

    # ONLY the downloaded copy is disposable - $book is the user's authoring workbook when
    # transport is 'workbook', and deleting it would destroy the design source.
    if ($tempBook -and $book -and (Test-Path $book)) { Remove-Item $book -Force -ErrorAction SilentlyContinue }

    if (-not $DiffOnly) {
        $meta = [ordered]@{
            syncedUtc     = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
            source        = $(if ($transport -eq 'workbook') { Split-Path -Leaf $book } else { [string]$cfg.sheetId })
            sourceSha256  = $(if ($transport -eq 'workbook') { (Get-FileHash -Algorithm SHA256 $book).Hash } else { '' })
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
        [switch]$RequireVerified,
        [switch]$SkipWorkbookCheck
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

    # Columns that are legitimately blank on some rows: SensorEval applies only to F-DI,
    # and Polarity is checked by a dedicated rule below that names the wiring drawing gap
    # instead of reporting a generic enum failure.
    $blankOk = @('21_Modules.SensorEval','23_Channels.Polarity')
    foreach ($k in $script:TiaSheetEnums.Keys) {
        $t, $c = $k -split '\.', 2
        if (-not $tabs.ContainsKey($t)) { continue }
        $allowed = $script:TiaSheetEnums[$k]
        $n = 0
        foreach ($r in $tabs[$t]) {
            $n++
            $v = [string]$r.$c
            if ([string]::IsNullOrWhiteSpace($v)) {
                if ($blankOk -contains $k) { continue }
                $errors.Add("${t} row ${n}: '$c' is blank (enum)"); continue
            }
            if ($allowed -cnotcontains $v) { $errors.Add("${t} row ${n}: '$c'='$v' not in {$($allowed -join ', ')}") }
        }
    }
    foreach ($r in $tabs['21_Modules']) {
        if ($r.Kind -eq 'F-DI' -and -not $r.SensorEval) {
            $errors.Add("21_Modules $($r.ModuleName): F-DI needs SensorEval (1oo1 or 1oo2)")
        }
        if ($r.Kind -notlike 'F-*' -and $r.SensorEval) {
            $errors.Add("21_Modules $($r.ModuleName): SensorEval is meaningless on a non-F module")
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

    $zones   = @{}; foreach ($r in $tabs['20_Stations'])  { $zones[$r.Zone] = $r }
    $devices = @{}; foreach ($r in $tabs['22_Devices']){ $devices[$r.DeviceID] = $r }
    $udts    = @{}; foreach ($r in $tabs['30_UDTs'])   { $udts[$r.UDT] = $true }
    $mods    = @{}; foreach ($r in $tabs['21_Modules']){ $mods["$($r.Zone)/$($r.ModuleName)"] = $r }

    $refSeen = @{}; $idSeen = @{}
    foreach ($r in $tabs['22_Devices']) {
        if (-not $zones.ContainsKey($r.Zone)) { $errors.Add("22_Devices $($r.DeviceID): unknown Zone '$($r.Zone)'") }
        if ($r.UDT -and -not $udts.ContainsKey($r.UDT)) { $errors.Add("22_Devices $($r.DeviceID): UDT '$($r.UDT)' not in 30_UDTs") }
        if ($idSeen.ContainsKey($r.DeviceID)) { $errors.Add("22_Devices: duplicate DeviceID '$($r.DeviceID)'") }
        else { $idSeen[$r.DeviceID] = $true }
        # DeviceRef becomes the F-DB member name, so it must be unique within its zone or
        # two devices silently share one set of safety data
        $k = "$($r.Zone)|$($r.DeviceRef)"
        if ($refSeen.ContainsKey($k)) {
            $errors.Add("22_Devices: zone $($r.Zone) has two devices with DeviceRef '$($r.DeviceRef)' ($($refSeen[$k]), $($r.DeviceID)) - they would collide as DB members")
        } else { $refSeen[$k] = $r.DeviceID }
    }
    $ipSeen = @{}; $dnSeen = @{}; $stSeen = @{}
    foreach ($r in $tabs['20_Stations']) {
        # A duplicate IP or PROFINET device number is a network fault the compiler will not
        # catch; a duplicate station name collides in the project tree.
        foreach ($pair in @(@('IpAddress',$ipSeen), @('DeviceNumber',$dnSeen), @('Station',$stSeen))) {
            $col = $pair[0]; $map = $pair[1]
            $v = [string]$r.$col
            if (-not $v) { continue }
            if ($map.ContainsKey($v)) { $errors.Add("20_Stations: $col '$v' used by both $($map[$v]) and $($r.Zone)") }
            else { $map[$v] = $r.Zone }
        }
        if ($r.IpAddress -and $r.IpAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            $errors.Add("20_Stations $($r.Zone): IpAddress '$($r.IpAddress)' is not a dotted IPv4 address")
        }
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
            if ("$($r.Slot)$($r.Channel)" -eq '') {
                $errors.Add("23_Channels ${id}: Slot/Channel required for a safety signal")
            } else {
                $key = "$z/$($r.Slot)/$($r.Channel)"
                if ($chanUse.ContainsKey($key)) { $errors.Add("23_Channels ${id}: channel $key already used by $($chanUse[$key])") }
                else { $chanUse[$key] = $id }
            }
            $g = "$($r.DeviceID)|$($r.Component)"
            if (-not $group.ContainsKey($g)) { $group[$g] = @{ Paired = $r.Paired; Sigs = @(); Mods = @() } }
            $group[$g].Sigs += $r.Signal
            $group[$g].Mods += [string]$r.Slot
            if ($group[$g].Paired -ne $r.Paired) { $errors.Add("23_Channels ${id}: inconsistent Paired within $g") }
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

    # Polarity is a wiring-drawing fact and cannot be inferred. A wrong guess inverts a
    # trip, so a blank is reported as a specific gap rather than silently defaulted.
    $noPol = @($tabs['23_Channels'] | Where-Object { $_.Signal -ne 'Diag' -and -not $_.Polarity })
    if ($noPol.Count) {
        # build the message first: inside Add(...) a comma binds to the method call, not
        # to -f, which silently turned this rule into a thrown FormatError
        $msg = "23_Channels: $($noPol.Count) safety channel(s) have no Polarity - it must " +
               "come from the wiring drawing, never a default (first: $($noPol[0].ChannelID))"
        $errors.Add($msg)
    }

    # UDT members referenced by the trip path must actually exist, or the generated
    # contacts point at nothing.
    $udtMembers = @{}
    foreach ($r in $tabs['30_UDTs']) {
        if (-not $udtMembers.ContainsKey($r.UDT)) { $udtMembers[$r.UDT] = @{} }
        $udtMembers[$r.UDT][$r.Member] = $true
    }

    # interlock coverage - a device wired and indicated but absent from the trip path
    # is worse than absent, because it looks functional
    $inter = @{}
    foreach ($r in $tabs['34_Interlocks']) {
        if (-not $devices.ContainsKey($r.DeviceID)) { $errors.Add("34_Interlocks: unknown DeviceID '$($r.DeviceID)'"); continue }
        if ($r.Include -eq 'Yes') { $inter[$r.DeviceID] = $true }
        elseif (-not $r.Rationale) { $errors.Add("34_Interlocks $($r.DeviceID): Include=No requires a Rationale") }
        $leaf = ($r.Member -split '\.')[-1]
        $u = $devices[$r.DeviceID].UDT
        if ($leaf -and $u -and $udtMembers.ContainsKey($u) -and -not $udtMembers[$u].ContainsKey($leaf)) {
            $errors.Add("34_Interlocks $($r.DeviceID): Member '$($r.Member)' - '$leaf' is not a member of $u")
        }
    }
    foreach ($d in $tabs['22_Devices']) {
        if ($d.InInterlock -eq 'Yes' -and -not $inter.ContainsKey($d.DeviceID)) {
            $errors.Add("34_Interlocks: device $($d.DeviceID) is InInterlock=Yes but not included in any interlock target")
        }
    }

    # 31_Policy drives certified-block generation, so every wired device/component pair
    # must resolve to a rule - an unmatched device would silently get no evaluation.
    $policy = @{}
    foreach ($r in $tabs['31_Policy']) {
        $pk = "$($r.DeviceType)|$($r.Component)"
        if (-not $policy.ContainsKey($pk)) { $policy[$pk] = @() }
        $policy[$pk] += $r
    }
    $override = @{}
    foreach ($r in $tabs['33_SafetyBlocks']) { $override["$($r.DeviceID)|$($r.Component)"] = $true }
    foreach ($g in $group.Keys) {
        $did, $comp = $g -split '\|', 2
        if (-not $devices.ContainsKey($did)) { continue }
        $dt = $devices[$did].DeviceType
        $pk = "$dt|$comp"
        if (-not $policy.ContainsKey($pk)) {
            if (-not $override.ContainsKey($g)) {
                $errors.Add("31_Policy: no rule for DeviceType '$dt' component '$comp' (e.g. $did) - it would get no certified evaluation")
            }
            continue
        }
        # a 1oo2 evaluator needs two channels; a single-channel device cannot use one
        if ($group[$g].Paired -ne 'Yes') {
            foreach ($p in $policy[$pk]) {
                if ($p.Instruction -eq 'EV1oo2DI') {
                    $errors.Add("31_Policy $($p.PolicyID): $did.$comp is single-channel (Paired=No) but policy applies EV1oo2DI, which needs ChA and ChB")
                }
            }
        }
    }
    foreach ($r in $tabs['31_Policy']) {
        foreach ($tp in @('DISCTIME','TIME_DEL')) {
            $v = [string]$r.$tp
            if ($v -and $v -notmatch '^(?i)T#') { $errors.Add("31_Policy $($r.PolicyID): $tp '$v' is not IEC time (T#500ms)") }
        }
        if ($r.Instruction -eq 'EV1oo2DI' -and -not $r.DISCTIME) {
            $warns.Add("31_Policy $($r.PolicyID): EV1oo2DI without DISCTIME - discrepancy time is a safety parameter")
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

    # STALE SNAPSHOT GUARD. design/csv only changes when Sync runs, so an edited workbook
    # that was never synced would build the OLD design silently - the exact failure the
    # snapshot exists to prevent. Compare by CONTENT: the workbook's bytes change on every
    # Excel save (zip timestamps), so a file hash would cry wolf on every save.
    if (-not $SkipWorkbookCheck) {
        $designDir = Split-Path -Parent $Path
        if ($designDir -and (Test-Path $designDir)) {
            $wb = @(Get-ChildItem -Path $designDir -Filter '*.xlsx' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '~$*' })
            if ($wb.Count -eq 1) {
                try {
                    $d = Sync-TiaDesignSheet -Path $designDir -DiffOnly -Quiet
                    if ($d.Changed -and $d.Changed.Count) {
                        # build the string first - a comma inside Add(...) binds to the
                        # method call, not to -f, and would throw instead of reporting
                        $msg = "STALE SNAPSHOT: $($wb[0].Name) has unsynced changes in " +
                               "$($d.Changed -join ', ') - run Sync-TiaDesignSheet. " +
                               "The build reads $(Split-Path -Leaf $Path), not the workbook."
                        $errors.Add($msg)
                    }
                } catch {
                    $warns.Add("could not compare $($wb[0].Name) against the snapshot: $($_.Exception.Message)")
                }
            }
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
        $tabs['20_Stations'].Count, $tabs['21_Modules'].Count, $tabs['22_Devices'].Count,
        $tabs['23_Channels'].Count, $tabs['33_SafetyBlocks'].Count, $unver)
    [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors; Warnings = $warns; Summary = $summary }
}
