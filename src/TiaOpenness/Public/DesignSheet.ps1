# Design-sheet ingestion + validation.
# Schema contract: docs/DESIGN-SHEET.md
#
# Sync-TiaDesignSheet is the ONLY networked cmdlet in this module. It is an explicit,
# on-demand sync into a COMMITTED CSV snapshot - never a build-time dependency, so the
# build stays reproducible from a git checkout and CI stays offline.

$script:TiaSheetSchemaVersion = '1.9'

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
#     F-DI sensor evaluation, so SensorEval recorded the INTENDED value for the manual TIA
#     step. (Removed again in v1.5 - see below.)
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
#
# v1.3 changes:
#   - The key column is 'Area' in EVERY tab (was 'Zone' in 21/22/32/34 and 'Zone' as
#     20_Stations' own key). One name for one thing: a row's Area is the key into
#     20_Stations, and {Area} is the naming placeholder. 'Zone' is gone from the schema -
#     it collided with the radiation-safety meaning of "zone" in the drawings.
#   - 20_Stations' remaining columns adopt underscore names (Station_Name, Station_Label,
#     IO_System, IP_Address, Subnet_Mask, Device_Number, Device_Name), separating the
#     station's TIA name from the Area key that used to be called Station.
#   - 10_Project: CpuLocalZone -> CpuLocalArea (its value is an Area key).
#
# v1.4 changes - ONE data block, THREE program blocks:
#   - 22_Devices.DeviceRef -> Device (and the {Device} naming placeholder).
#   - Areas become UDTs. The build generates one UDT per area from 22_Devices and
#     instantiates all of them in a single system F-DB, replacing the 16 per-area F-DBs.
#     A member path gains an area level: DB_SR_PPS.BTA.SE0101.EMO.ChA.
#   - One F-FB per LAYER for the whole system (IOMap / Certified / Safety) instead of one
#     per area per layer, so BlockPattern loses {Area}. The safety runtime calls 3 blocks.
#     Trade-off to know: an F-signature now covers the whole program, so any edit re-signs
#     everything - the per-area boundary for change-impact analysis is gone.
#   - {InputType} tag prefix: fi/fo (fail-safe in/out) or ni/no (standard), derived from
#     the channel's module Kind, so a tag name states its own safety class.
#
# v1.5 changes:
#   - 21_Modules.SensorEval REMOVED. Decision D01 fixes hardware evaluation at 1oo1 for
#     every F-DI and does the 1oo2 in software (EV1oo2DI), so the column restated one
#     project-wide decision on 42 rows. Worse, it looked like a build input and was not:
#     Openness exposes no sensor-evaluation parameter at all - 37 Failsafe_* attributes on
#     an F-DI, none of them evaluation - so the engine can neither set it NOR read it back
#     to check. It is a manual TIA step with no automated verification, and saying that
#     once in the docs is honest where a per-module column implied a check that never ran.
#
# v1.6 changes - UDT_SafeInput vocabulary (data, not schema: 30_UDTs is authored):
#   - 1oo2_OK -> Eval_OK. A leading digit is not a bare-legal S7 identifier, so every SCL
#     reference had to quote it. Eval_OK is legal, keeps the house _OK suffix, and names
#     the STAGE - the three safe-ish values now read ChA/ChB -> Eval_OK -> Safe.
#   - Discrepancy -> Disc_Flt, AckReq -> Ack_Req: each mirrors the certified pin that
#     drives it (DISC_FLT, ACK_REQ), so a reviewer holding the Siemens safety manual maps
#     member to pin without a lookup table.
#   - Fault and Latch dropped: nothing wrote either. Fault matched no pin at all, and
#     ESTOP1 already latches internally until acknowledged. A member nothing writes reads
#     as working logic and is permanently FALSE - it looks safe and is silently broken.
#   - Device_Safe dropped from UDT_SafeInput: with one component it was an AND of one term,
#     a second name for .Safe. Multi-component types (UDT_SCB, UDT_CSD) keep it. The build
#     picks the right contributor per device, so 34_Interlocks never has to know the shape.
#   - ACK_REQ / DISC_FLT / Q_DELAY are now WIRED instead of going to OpenCon, but only where
#     the resolved UDT declares a landing member. Only the TERMINAL instruction publishes
#     ACK_REQ - both halves of a chained pair produce one, and wiring both would drive one
#     coil from two networks.
#   - DIAG is NOT landed anywhere and stays OpenCon. It is a BYTE, and BYTE is not an
#     F-compliant type, so it cannot live in an F-DB in any form: as Byte the F-UDT is
#     rejected, and as Bool the UDT compiles and then EVERY certified network fails the
#     connection type check. It is deliberately non-safety-related service information that
#     Siemens intends for a STANDARD DB. New validation rule 16 catches the whole class.
#   - New authored types UDT_EMO (adds Safe_Delayed for ESTOP1.Q_DELAY) and UDT_Door
#     (SFDOOR alone - no Eval_OK/Disc_Flt, since SFDOOR has neither pin).
#
# v1.7 changes - the legacy/as-built record is retired:
#   - 23_Channels.LegacyTagName REMOVED. It held the old system's tag for the same
#     contact. Nothing in the build ever read it; it existed to cross-check a seeded
#     design against the system being replaced. Once a design is authored rather than
#     inferred, that column is a second identity for a device and invites the reader to
#     trust whichever of the two names they saw last.
#   - 21_Modules.AsBuiltRail REMOVED. Recorded which physical rail a module sat on in the
#     old rack. Never read; the rack this project builds is described by Area+Slot.
#   - 20_Stations.Station_Label REMOVED. It duplicated Station_Name verbatim and was only
#     folded into the station's device comment, where it deduplicated to nothing.
#   - Terminal is KEPT: it is the field terminal a device lands on in the design being
#     built, not a record of the system being replaced.
#
#   Consequence to be aware of: the seeded provenance is now git history, not sheet data.
#   Any device grouping that was justified by a legacy tag must be justified by a drawing
#   reference from here on - which is what DrawingRef is for.
#
# v1.8 changes - 22_Devices REMOVED; the area UDTs are authored:
#   - The Area UDTs are declared in 30_UDTs like any other type, instead of being invented
#     by the build from 22_Devices. That also makes Area_Reset / Interlocks_OK / Area_Safe
#     real rows: they were referenced by 31_Policy.AckSource and 34_Interlocks.Target while
#     being declared nowhere, which is exactly the hidden constant this schema exists to
#     prevent. The build still generates them for a sheet that predates this, but authored
#     rows always win.
#   - 22_Devices is then redundant. A device IS a member of its area's UDT, so the member
#     row already carries the name, the type and the description. The device list is
#     derived from those rows and DeviceID - still the key 23_Channels and 34_Interlocks
#     join on - is exactly "{Area}_{Member}".
#   - 31_Policy drops DeviceType and keys on UDT + Component. Its UDT column used to hold
#     the COMPONENT's type (UDT_SafeInput on every row, saying nothing); it now holds the
#     type of the device the rule applies to. Keying on the UDT means a rule cannot be
#     matched to a device whose data structure has nowhere to put the result - a guarantee
#     a free-text DeviceType label never gave.
#   - Interlock coverage no longer keys off 22_Devices.InInterlock. The rule is now: a
#     device with channels must appear in 34_Interlocks, included or excluded-with-reason.
#
# v1.9 changes - 34_Interlocks becomes a cause-and-effect matrix:
#   - The tab is now a grid: one ROW per (Area, Target), one COLUMN per DeviceID, a mark
#     where that device feeds that target. Long form said the same thing in 46 rows and
#     buried the question a reviewer actually asks - "what feeds this target, and what
#     feeds nothing?" - in a list you have to sort to read. In a grid an unused device is
#     an empty column, visible without a query.
#   - DeviceID, Member and Include are gone. DeviceID became the column header; Include
#     became the mark; Member was never read - the build computes each device's terminal
#     contributor itself (Device_Safe for a multi-component type, the component's own
#     terminal output otherwise), so the column could only ever disagree with the build.
#   - EVERY device gets a column, whether marked or not. The grid is a coverage claim, so
#     a device missing from it is a device nobody considered - which is the thing being
#     checked, and cannot be allowed to look identical to "considered and excluded".
#   - Rationale moves to a new 34_Exclusions tab (DeviceID, Rationale, SF_ID). It is a
#     per-device fact and there is no cell to put it in; keeping the requirement is what
#     matters - an empty column is only acceptable if someone wrote down why.
#   - A mark is only valid for a device in the target's OWN area. The build ANDs per area,
#     so a cross-area mark would build nothing at all, and the grid makes such a mark
#     trivially easy to enter by accident.
$script:TiaSheetSchema = [ordered]@{
    '10_Project'     = @('Key','Value','Notes')
    '20_Stations'    = @('Area','Name','Description','Station_Name','IM_MLFB','IM_FW','IO_System','IP_Address','Subnet_Mask','Device_Number','Device_Name','Verified','Notes')
    '21_Modules'     = @('Area','Slot','Kind','MLFB','FW','ModuleName','InputBytes','F_DestAddr','F_MonitorTime','DrawingRef','Verified','Comment')
    '23_Channels'    = @('ChannelID','DeviceID','Component','Signal','Paired','Invert','Slot','Channel','Terminal','ModuleName','DrawingRef','Description','Verified')
    '30_UDTs'        = @('UDT','Order','Member','Datatype','Comment','FailsafeCompliant')
    '31_Policy'      = @('PolicyID','UDT','Component','Order','Instruction','Version','DISCTIME','TIME_DEL','ACK_NEC','OPEN_NEC','AckSource','QTarget','Rationale','Verified')
    '32_Blocks'      = @('Block','Area','Layer','Language','Number','Description')
    '33_SafetyBlocks'= @('RowID','DeviceID','Component','Instruction','Version','InstanceName','DISCTIME','TIME_DEL','ACK_NEC','OPEN_NEC','AckSource','QTarget','Verified','Notes')
    # A matrix tab: these two columns are fixed and every FURTHER column is a DeviceID,
    # so the schema states the prefix and the interlock rules check the rest.
    '34_Interlocks'  = @('Area','Target')
}
# closed enum sets: "Tab.Column" -> allowed values
$script:TiaSheetEnums = @{
    '21_Modules.Kind'            = @('IM','F-DI','F-DQ','F-RQ','DI','DQ')
    '23_Channels.Signal'         = @('ChA','ChB','Diag')
    '23_Channels.Paired'         = @('Yes','No')
    '23_Channels.Invert'         = @('Yes','No')
    '31_Policy.Instruction'      = @('ESTOP1','SFDOOR','EV1oo2DI','FDBACK','ACK_GL')
    '32_Blocks.Layer'            = @('IOMap','Safety','Certified','Runtime','Data')
    '32_Blocks.Language'         = @('F_LAD','F_DB','F_FBD','LAD','SCL')
    '33_SafetyBlocks.Instruction'= @('ESTOP1','SFDOOR','EV1oo2DI','FDBACK','ACK_GL')
    '34_Interlocks.Target'       = @('Interlocks_OK','Area_Safe')
}
$script:TiaSheetVerifiedCols = @('20_Stations','21_Modules','23_Channels','31_Policy','33_SafetyBlocks')

# Matrix tabs: tab -> the fixed leading (key) columns. Every column after those is a
# dynamic header - a DeviceID - and the cell under it is a mark or empty. Declared here so
# the validator, the model and the workbook exporter all agree on where the keys stop.
$script:TiaSheetMatrixTabs = [ordered]@{ '34_Interlocks' = @('Area','Target') }
$script:TiaSheetMatrixMark = 'X'

# Headers for every known tab, including the optional/governance ones. Used to preserve a
# tab's header when it legitimately has zero data rows (the xlsx reader consumes row 1 as
# the header, so an empty tab would otherwise lose its schema on sync).
$script:TiaSheetKnownHeaders = [ordered]@{
    '01_Revisions' = @('Rev','Date','Author','Summary','Approver','SnapshotCommit')
    '02_Decisions' = @('DecID','Topic','Question','Decision','Rationale','Status','Owner','Date')
    '34_Exclusions'= @('DeviceID','Rationale','SF_ID')
    '35_Outputs'   = @('OutputID','Area','DeviceID','Signal','Slot','Channel','DrivenBy','FDBACK')
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
            sourceSha256  = $(if ($transport -eq 'workbook') { Get-TiaSharedFileHash -Path $book } else { '' })
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
    # Optional tabs: absent is legitimate (nothing excluded, no outputs authored yet), so
    # they carry no "missing tab" error - but their rules still run when they are present.
    foreach ($t in @('34_Exclusions')) {
        $f = Join-Path $Path "$t.csv"
        $tabs[$t] = if (Test-Path $f) { @(Import-Csv $f | Where-Object { $_ }) } else { @() }
    }
    if ($errors.Count) {
        return [pscustomobject]@{ Ok=$false; Errors=$errors; Warnings=$warns; Summary='schema failed' }
    }

    # A blank Invert means "follows the fail-safe convention" (the overwhelmingly common
    # case), so requiring an explicit 'No' on 180-odd rows would be noise.
    $blankOk = @('23_Channels.Invert')
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
    # project keys - these drive project creation, so missing ones are hard errors
    $proj = @{}
    foreach ($r in $tabs['10_Project']) { if ($r.Key) { $proj[$r.Key] = [string]$r.Value } }
    foreach ($k in @('ProjectName','PlcName','CpuMLFB','CpuFW','SubnetName','IoSystemName',
                     'SafetyRuntimeFB','TagTableIn','TagPattern','DbPattern','BlockPattern',
                     'InstancePattern','BlockNumberBase','BlockNumberStep','ModulePattern',
                     'AreaUdtPattern')) {
        if (-not $proj.ContainsKey($k) -or -not $proj[$k]) { $errors.Add("10_Project: missing key '$k'") }
    }
    if ($proj['SchemaVersion'] -and ([version]$proj['SchemaVersion'] -gt [version]$script:TiaSheetSchemaVersion)) {
        $errors.Add("10_Project: SchemaVersion $($proj['SchemaVersion']) is newer than this engine supports ($script:TiaSheetSchemaVersion)")
    }

    $areas   = @{}; foreach ($r in $tabs['20_Stations'])  { $areas[$r.Area] = $r }
    $udts    = @{}; foreach ($r in $tabs['30_UDTs'])   { $udts[$r.UDT] = $true }
    $mods    = @{}; foreach ($r in $tabs['21_Modules']){ $mods["$($r.Area)/$($r.ModuleName)"] = $r }

    # A device is a member of its area's UDT. Mirror what the model does so the rules below
    # read the same list the build will.
    $areaPat = [string]$proj['AreaUdtPattern']
    if (-not $areaPat) { $areaPat = 'UDT_Area_{Area}' }
    $areaScalars = @('Area_Reset', 'Interlocks_OK', 'Area_Safe')
    $areaByUdt = @{}
    foreach ($a in $areas.Keys) { $areaByUdt[($areaPat -replace '\{Area\}', $a)] = $a }

    # @($null) is a ONE-element array in PowerShell, so filter rather than trust .Count
    $deviceRows = @($tabs['22_Devices'] | Where-Object { $_ })
    if (-not $deviceRows.Count) {
        $deviceRows = @()
        foreach ($u in $tabs['30_UDTs']) {
            if (-not $areaByUdt.ContainsKey($u.UDT)) { continue }
            if ($areaScalars -contains $u.Member) { continue }
            $a = $areaByUdt[$u.UDT]
            $deviceRows += [pscustomobject]@{
                DeviceID = "${a}_$($u.Member)"; Area = $a; Device = $u.Member
                UDT = ([string]$u.Datatype).Trim().Trim('"'); Description = $u.Comment
                InInterlock = ''; SF_ID = ''; Verified = ''
            }
        }
    }
    $devices = @{}; foreach ($r in $deviceRows) { $devices[$r.DeviceID] = $r }

    $refSeen = @{}; $idSeen = @{}
    foreach ($r in $deviceRows) {
        if (-not $areas.ContainsKey($r.Area)) { $errors.Add("device $($r.DeviceID): unknown Area '$($r.Area)'") }
        if ($r.UDT -and -not $udts.ContainsKey($r.UDT)) { $errors.Add("device $($r.DeviceID): UDT '$($r.UDT)' not in 30_UDTs") }
        if ($idSeen.ContainsKey($r.DeviceID)) { $errors.Add("duplicate DeviceID '$($r.DeviceID)'") }
        else { $idSeen[$r.DeviceID] = $true }
        # Device becomes the F-DB member name, so it must be unique within its area or
        # two devices silently share one set of safety data
        $k = "$($r.Area)|$($r.Device)"
        if ($refSeen.ContainsKey($k)) {
            $errors.Add("area $($r.Area) has two devices named '$($r.Device)' ($($refSeen[$k]), $($r.DeviceID)) - they would collide as DB members")
        } else { $refSeen[$k] = $r.DeviceID }
    }
    $ipSeen = @{}; $dnSeen = @{}; $stSeen = @{}; $maskByIo = @{}
    foreach ($r in $tabs['20_Stations']) {
        # A duplicate IP or PROFINET device number is a network fault the compiler will not
        # catch; a duplicate station name collides in the project tree.
        foreach ($pair in @(@('IP_Address',$ipSeen), @('Device_Number',$dnSeen), @('Station_Name',$stSeen))) {
            $col = $pair[0]; $map = $pair[1]
            $v = [string]$r.$col
            if (-not $v) { continue }
            if ($map.ContainsKey($v)) { $errors.Add("20_Stations: $col '$v' used by both $($map[$v]) and $($r.Area)") }
            else { $map[$v] = $r.Area }
        }
        if ($r.IP_Address -and $r.IP_Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            $errors.Add("20_Stations $($r.Area): IP_Address '$($r.IP_Address)' is not a dotted IPv4 address")
        }
        # A subnet mask must be a run of 1-bits followed by 0-bits. Excel drag-fill happily
        # produces 255.255.255.1, .2, .3 - each a valid-LOOKING dotted quad that no station
        # will ever come online with, and nothing downstream would have complained.
        if ($r.Subnet_Mask) {
            $bad = Test-TiaSubnetMask -Mask $r.Subnet_Mask
            if ($bad) { $errors.Add("20_Stations $($r.Area): Subnet_Mask '$($r.Subnet_Mask)' $bad") }
            elseif ($r.IO_System) {
                # every station on one IO system shares one subnet, by definition
                if (-not $maskByIo.ContainsKey($r.IO_System)) { $maskByIo[$r.IO_System] = @{} }
                $maskByIo[$r.IO_System][$r.Subnet_Mask] = $r.Area
            }
        }
    }
    foreach ($io in $maskByIo.Keys) {
        if ($maskByIo[$io].Count -gt 1) {
            $seen = ($maskByIo[$io].Keys | Sort-Object) -join ', '
            $errors.Add("20_Stations: IO system '$io' has stations on $($maskByIo[$io].Count) different subnet masks ($seen) - one IO system is one subnet")
        }
    }
    # F-destination addresses: unique network-wide, and the compiler never checks them.
    # TIA only auto-assigns through the GUI, so an unfilled column means every F-module in
    # an Openness build keeps the catalogue default and they all collide.
    $fMods = @($tabs['21_Modules'] | Where-Object { $_.Kind -like 'F-*' })
    $fDeclared = @($fMods | Where-Object { $_.F_DestAddr })
    if ($fMods.Count -and -not $fDeclared.Count) {
        $warns.Add("21_Modules: no F_DestAddr on any of $($fMods.Count) F-module(s) - TIA does not auto-assign these through Openness, so they all keep the catalogue default and collide. They must match the BaseUnit DIP switches.")
    } elseif ($fDeclared.Count -and $fDeclared.Count -lt $fMods.Count) {
        $warns.Add("21_Modules: F_DestAddr on $($fDeclared.Count) of $($fMods.Count) F-module(s) - a partly assigned set can collide with the defaults on the rest")
    }
    $fSeen = @{}
    foreach ($r in $fDeclared) {
        if ($fSeen.ContainsKey($r.F_DestAddr)) {
            $errors.Add("21_Modules: F_DestAddr $($r.F_DestAddr) used by both $($fSeen[$r.F_DestAddr]) and $($r.Area)/$($r.ModuleName) - it must be unique network-wide")
        } else { $fSeen[$r.F_DestAddr] = "$($r.Area)/$($r.ModuleName)" }
    }

    $modNameSeen = @{}
    $modPattern = $proj['ModulePattern']
    foreach ($r in $tabs['21_Modules']) {
        if (-not $areas.ContainsKey($r.Area)) { $errors.Add("21_Modules $($r.ModuleName): unknown Area '$($r.Area)'") }
        $slot = 0
        if (-not [int]::TryParse([string]$r.Slot, [ref]$slot)) { $errors.Add("21_Modules $($r.ModuleName): Slot '$($r.Slot)' is not an integer") }
        # 23_Channels joins on Area+ModuleName, so a duplicate silently merges two racks'
        # worth of channels onto one module.
        $mk = "$($r.Area)/$($r.ModuleName)"
        if ($modNameSeen.ContainsKey($mk)) { $errors.Add("21_Modules: area $($r.Area) has two modules named '$($r.ModuleName)' (slots $($modNameSeen[$mk]) and $($r.Slot))") }
        else { $modNameSeen[$mk] = $r.Slot }
        # ModuleName stays authored data (it is a foreign key), but drift from the declared
        # convention is reported so the names stay predictable across 76 modules.
        if ($modPattern -and $r.ModuleName -and $r.Kind) {
            $want = Expand-TiaSheetPattern -Pattern $modPattern -Values @{
                Area = $r.Area; Kind = (Get-TiaModuleKindToken $r.Kind); Slot = $r.Slot }
            if ($r.ModuleName -cne $want) {
                $warns.Add("21_Modules $($r.Area) slot $($r.Slot): ModuleName '$($r.ModuleName)' does not match ModulePattern (expected '$want')")
            }
        }
    }

    # channels: referential + safety
    $chanUse = @{}; $group = @{}
    foreach ($r in $tabs['23_Channels']) {
        $id = $r.ChannelID
        if (-not $devices.ContainsKey($r.DeviceID)) { $errors.Add("23_Channels ${id}: unknown DeviceID '$($r.DeviceID)'"); continue }
        $z = $devices[$r.DeviceID].Area
        if ($r.ModuleName -and -not $mods.ContainsKey("$z/$($r.ModuleName)")) {
            $errors.Add("23_Channels ${id}: ModuleName '$($r.ModuleName)' not a module of area $z")
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

    # SIGNAL SENSE. The project convention is fail-safe: at the PLC input, 1 = OK and
    # 0 = fault/demand, so a channel maps straight through. Invert=Yes marks a field device
    # wired the other way round and the IOMap negates that contact.
    #
    # This is a declared convention, not a guess - but a channel that silently breaks it is
    # exactly the failure a blank cannot distinguish from a correct blank. The gate that
    # bites is therefore Verified on 23_Channels, not the presence of a value here.
    $inv = @($tabs['23_Channels'] | Where-Object { $_.Signal -ne 'Diag' -and $_.Invert -eq 'Yes' })
    if ($inv.Count) {
        $msg = "23_Channels: $($inv.Count) channel(s) are Invert=Yes - each emits a NEGATED " +
               "contact against the fail-safe convention (first: $($inv[0].ChannelID))"
        $warns.Add($msg)
    }
    $unverChan = @($tabs['23_Channels'] | Where-Object { $_.Signal -ne 'Diag' -and $_.Verified -ne 'Yes' })
    if ($unverChan.Count) {
        # A blank Invert asserts "this channel is fail-safe". Nothing in the data can prove
        # that; only a person reading the drawing can, and Verified is where they say so.
        $msg = "23_Channels: $($unverChan.Count) safety channel(s) are Verified<>Yes - the " +
               "fail-safe sense of each is unconfirmed against the wiring drawing"
        $warns.Add($msg)
    }

    # UDT members referenced by the trip path must actually exist, or the generated
    # contacts point at nothing.
    $udtMembers = @{}
    foreach ($r in $tabs['30_UDTs']) {
        if (-not $udtMembers.ContainsKey($r.UDT)) { $udtMembers[$r.UDT] = @{} }
        $udtMembers[$r.UDT][$r.Member] = $true
    }

    # A UDT marked FailsafeCompliant=Yes lands in an F-DB, and an F-DB accepts only the
    # F-compliant elementary types. Byte/DByte/Real/etc are rejected by TIA at compile
    # time, several phases after the sheet looks fine - so catch it offline. This is how
    # the certified DIAG output (a BYTE) gets caught: it cannot live in an F-DB at all.
    $fTypes = @('Bool','Int','DInt','Word','Time')
    foreach ($r in $tabs['30_UDTs']) {
        if ($r.FailsafeCompliant -ne 'Yes') { continue }
        $t = ([string]$r.Datatype).Trim().Trim('"')
        if (-not $t) { continue }
        # a nested UDT reference is fine as long as that UDT is itself F-compliant
        if ($udtMembers.ContainsKey($t)) { continue }
        if ($t -notin $fTypes) {
            $errors.Add("30_UDTs $($r.UDT).$($r.Member): datatype '$t' is not F-compliant (allowed: $($fTypes -join ', '), or a nested F-compliant UDT)")
        }
    }

    # MIGRATION CROSS-CHECK. While both exist, an authored UDT_Area_* must describe exactly
    # what 22_Devices does for that area - same members, same types. This is what makes it
    # safe to delete 22_Devices: the equivalence is proved rather than assumed.
    $areaPat = ''
    foreach ($r in $tabs['10_Project']) { if ($r.Key -eq 'AreaUdtPattern') { $areaPat = [string]$r.Value } }
    if (-not $areaPat) { $areaPat = 'UDT_Area_{Area}' }
    $authoredAreas = @($tabs['30_UDTs'] | Where-Object { $_.UDT -like ($areaPat -replace '\{Area\}', '*') })
    if ($authoredAreas.Count -and @($tabs['22_Devices'] | Where-Object { $_ }).Count) {
        $scalars = @('Area_Reset', 'Interlocks_OK', 'Area_Safe')
        foreach ($a in $areas.Keys) {
            $an = $areaPat -replace '\{Area\}', $a
            $auth = @{}
            foreach ($r in ($authoredAreas | Where-Object { $_.UDT -eq $an })) {
                if ($scalars -contains $r.Member) { continue }
                $auth[$r.Member] = ([string]$r.Datatype).Trim().Trim('"')
            }
            $fromDev = @{}
            foreach ($d in ($tabs['22_Devices'] | Where-Object { $_.Area -eq $a })) { $fromDev[$d.Device] = $d.UDT }
            foreach ($m in $auth.Keys) {
                if (-not $fromDev.ContainsKey($m)) { $errors.Add("30_UDTs ${an}: member '$m' has no matching 22_Devices row in area $a") }
                elseif ($fromDev[$m] -ne $auth[$m]) { $errors.Add("30_UDTs ${an}.${m}: type '$($auth[$m])' but 22_Devices says '$($fromDev[$m])'") }
            }
            foreach ($m in $fromDev.Keys) {
                if (-not $auth.ContainsKey($m)) { $errors.Add("22_Devices: $a device '$m' is missing from the authored $an") }
            }
            foreach ($s in $scalars) {
                if (-not ($authoredAreas | Where-Object { $_.UDT -eq $an -and $_.Member -eq $s })) {
                    $errors.Add("30_UDTs ${an}: no '$s' member - 31_Policy.AckSource and 34_Interlocks.Target reference it")
                }
            }
        }
    }

    # interlock coverage - a device wired and indicated but absent from the trip path
    # is worse than absent, because it looks functional.
    #
    # 34_Interlocks is a grid: rows are targets, columns are devices, a mark is a
    # contribution. Expand it exactly as the model does, so what is validated here is what
    # the build will read.
    $mx = Expand-TiaSheetInterlockMatrix -Rows $tabs['34_Interlocks']
    foreach ($e in $mx.Errors) { $errors.Add($e) }

    # A mistyped column header would otherwise be a whole column of marks contributing
    # nothing, and a device with NO column is one nobody has considered - which must not
    # look the same as one considered and left out.
    foreach ($c in $mx.Columns) {
        if (-not $devices.ContainsKey($c)) { $errors.Add("34_Interlocks: column '$c' is not a DeviceID") }
    }
    foreach ($did in ($devices.Keys | Sort-Object)) {
        if ($mx.Columns -notcontains $did) {
            $errors.Add("34_Interlocks: no column for device '$did' - every device is a column, marked or not, because the grid is the coverage claim")
        }
    }
    $rowSeen = @{}
    $n = 0
    foreach ($r in $tabs['34_Interlocks']) {
        $n++
        if (-not $areas.ContainsKey($r.Area)) { $errors.Add("34_Interlocks row ${n}: unknown Area '$($r.Area)'") }
        # Two rows for one target would each build a rung driving the same coil.
        $k = "$($r.Area)|$($r.Target)"
        if ($rowSeen.ContainsKey($k)) { $errors.Add("34_Interlocks: two rows for $($r.Area) $($r.Target)") }
        else { $rowSeen[$k] = $true }
    }
    $inter = @{}
    foreach ($r in $mx.Rows) {
        if (-not $devices.ContainsKey($r.DeviceID)) { continue }   # reported as a bad column
        $inter[$r.DeviceID] = $true
        # The build ANDs contributors per area, so a mark on a device from another area
        # builds nothing at all - and in a grid that mark is one cell away from a right one.
        $da = $devices[$r.DeviceID].Area
        if ($da -ne $r.Area) {
            $errors.Add("34_Interlocks: $($r.Area) $($r.Target) is marked for '$($r.DeviceID)', which belongs to area $da - a target is ANDed from its own area's devices, so this mark would build nothing")
        }
    }
    # An exclusion is a per-device fact with no cell to live in, so it gets its own tab -
    # and the reason is the whole content of the row.
    $excl = @{}
    foreach ($r in $tabs['34_Exclusions']) {
        if (-not $r.DeviceID) { continue }
        if (-not $devices.ContainsKey($r.DeviceID)) { $errors.Add("34_Exclusions: unknown DeviceID '$($r.DeviceID)'"); continue }
        if (-not $r.Rationale) { $errors.Add("34_Exclusions $($r.DeviceID): a Rationale is required - it is the entire content of the row"); continue }
        $excl[$r.DeviceID] = $true
    }
    # Coverage: a device that is wired has a safety result, and that result either feeds the
    # trip path or is explicitly excluded with a reason. Silence is the failure mode this
    # catches - a device present, evaluated, and quietly contributing to nothing.
    $wired = @{}
    foreach ($g in $group.Keys) { $wired[(($g -split '\|', 2)[0])] = $true }
    foreach ($did in ($wired.Keys | Sort-Object)) {
        if (-not $devices.ContainsKey($did)) { continue }
        if ($inter.ContainsKey($did)) {
            if ($excl.ContainsKey($did)) {
                $errors.Add("34_Exclusions: $did is listed as excluded but is also marked in 34_Interlocks - one of the two is wrong")
            }
            continue
        }
        if ($excl.ContainsKey($did)) { continue }
        $errors.Add("34_Interlocks: $did has channels and a certified result but is marked against no target - mark it, or list it in 34_Exclusions with a Rationale")
    }

    # 31_Policy drives certified-block generation, so every wired device/component pair
    # must resolve to a rule - an unmatched device would silently get no evaluation.
    $policy = @{}
    foreach ($r in $tabs['31_Policy']) {
        $pk = "$(([string]$r.UDT).Trim().Trim('"'))|$($r.Component)"
        if (-not $policy.ContainsKey($pk)) { $policy[$pk] = @() }
        $policy[$pk] += $r
    }
    $override = @{}
    foreach ($r in $tabs['33_SafetyBlocks']) { $override["$($r.DeviceID)|$($r.Component)"] = $true }
    foreach ($g in $group.Keys) {
        $did, $comp = $g -split '\|', 2
        if (-not $devices.ContainsKey($did)) { continue }
        $dt = $devices[$did].UDT
        $pk = "$dt|$comp"
        if (-not $policy.ContainsKey($pk)) {
            if (-not $override.ContainsKey($g)) {
                $errors.Add("31_Policy: no rule for UDT '$dt' component '$comp' (e.g. $did) - it would get no certified evaluation")
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
            # A second workbook in design/ (an IO list, a vendor sheet) must not quietly
            # disable this guard - that would turn "I dropped a file in the folder" into
            # "the stale-snapshot check stopped running", with no message. Identify the
            # DESIGN workbook by its schema tabs; only give up if that is still ambiguous.
            if ($wb.Count -gt 1) {
                $design = @($wb | Where-Object {
                    $names = @()
                    try { $names = Get-TiaXlsxSheetName -Path $_.FullName } catch { }
                    ($names -contains '10_Project') -and ($names -contains '30_UDTs')
                })
                if ($design.Count -eq 1) {
                    $others = @($wb | Where-Object { $_.FullName -ne $design[0].FullName } |
                                ForEach-Object { $_.Name })
                    $warns.Add("$designDir holds $($wb.Count) .xlsx files - using '$($design[0].Name)' as the design workbook (ignoring $($others -join ', ')). Keep non-design workbooks outside design/ so this stays unambiguous.")
                    $wb = $design
                } else {
                    $errors.Add("$designDir holds $($wb.Count) .xlsx files and $($design.Count) of them look like the design workbook, so the STALE SNAPSHOT check could not run. Move the others out of design/, or name the design workbook in sheet.json.")
                    $wb = @()
                }
            }
            if ($wb.Count -eq 1) {
                try {
                    # pass the workbook explicitly - Sync's own auto-discovery throws when
                    # design/ holds more than one .xlsx, which is exactly the case above
                    $d = Sync-TiaDesignSheet -Path $designDir -Workbook $wb[0].FullName -DiffOnly -Quiet
                    if ($d.Changed -and $d.Changed.Count) {
                        # build the string first - a comma inside Add(...) binds to the
                        # method call, not to -f, and would throw instead of reporting
                        $msg = "STALE SNAPSHOT: $($wb[0].Name) has unsynced changes in " +
                               "$($d.Changed -join ', ') - run Sync-TiaDesignSheet. " +
                               "The build reads $(Split-Path -Leaf $Path), not the workbook."
                        $errors.Add($msg)
                    }
                    # We read the bytes Excel last WROTE, which is what a build would
                    # consume - but not what is on the author's screen. A clean compare
                    # while the book is open proves the saved state matches, nothing more.
                    if (Test-TiaXlsxOpenInExcel -Path $wb[0].FullName) {
                        $warns.Add("$($wb[0].Name) is open in Excel - only its SAVED state was compared; save and re-sync before relying on this")
                    }
                } catch {
                    # Fail CLOSED. If the workbook cannot be read we cannot prove the
                    # snapshot is current, and a warning here would let a build proceed on
                    # possibly stale safety data - the exact thing this guard exists to stop.
                    $lock = Join-Path $designDir ('~$' + $wb[0].Name)
                    $hint = if (Test-Path $lock) { ' It is open in Excel - close it and re-run.' } else { '' }
                    $errors.Add("cannot verify $($wb[0].Name) against the snapshot: $($_.Exception.Message)$hint")
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

    $summary = ("{0} areas, {1} modules, {2} devices, {3} channels, {4} safety blocks, {5} unverified" -f
        $tabs['20_Stations'].Count, $tabs['21_Modules'].Count, $deviceRows.Count,
        $tabs['23_Channels'].Count, $tabs['33_SafetyBlocks'].Count, $unver)
    [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = $errors; Warnings = $warns; Summary = $summary }
}
