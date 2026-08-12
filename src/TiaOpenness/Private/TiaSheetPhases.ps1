# Build phases for Invoke-TiaBuildFromSheet. Private so the module's public surface stays
# the documented cmdlet set; each phase has a fixed input/output contract (docs/DESIGN-SHEET.md
# and the project's docs/BUILD.md).

# Data types a fail-safe block may contain. REAL/LREAL/STRING are NOT F-compliant, and a
# non-compliant member in an F-DB is rejected at compile with an obscure message - catching
# it here names the offending member instead.
$script:TiaFailsafeTypes = @('bool','int','dint','word','dword','time','sint','usint',
                             'uint','udint','byte','char','void')

function Open-TiaSheetProject {
    <#
    .SYNOPSIS
        Attach to a fresh Portal instance and open the project a previous phase created.
    #>
    param([Parameter(Mandatory)][string]$ProjectPath)
    $file = $null
    foreach ($ext in @('ap19','ap20','ap21','ap18')) {
        $c = Join-Path $ProjectPath ((Split-Path -Leaf $ProjectPath) + ".$ext")
        if (Test-Path $c) { $file = $c; break }
    }
    if (-not $file) {
        $c = @(Get-ChildItem -Path $ProjectPath -Filter '*.ap*' -File -ErrorAction SilentlyContinue)
        if ($c.Count) { $file = $c[0].FullName }
    }
    if (-not $file) {
        throw ("No TIA project found at $ProjectPath - run -Phase Hardware first (phases are " +
               "additive and build into the same project).")
    }
    Connect-TiaPortal -New -WithUserInterface:$false | Out-Null
    # TIA holds the project lock for a short while after the previous Portal process exits
    # ("...can only be opened again after a 2 minute delay"), so running phases
    # back-to-back would otherwise fail on a race rather than a real problem.
    $deadline = (Get-Date).AddSeconds(150)
    while ($true) {
        try { Open-TiaProject -ProjectFile $file | Out-Null; break }
        catch {
            if ($_.Exception.Message -notmatch 'already been opened|cannot be accessed' -or (Get-Date) -gt $deadline) { throw }
            Write-Host '  project still locked by the previous phase - retrying...' -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }
    $file
}

function Test-TiaFailsafeType {
    <#
    .SYNOPSIS
        Is this member datatype usable inside a fail-safe block?
    #>
    param([string]$Datatype, $KnownUdts)
    $t = ([string]$Datatype).Trim().Trim('"')
    if ($script:TiaFailsafeTypes -contains $t.ToLowerInvariant()) { return $true }
    if ($KnownUdts -contains $t) { return $true }   # nested UDT, checked on its own rows
    $false
}

function Get-TiaSheetBlockNumber {
    <#
    .SYNOPSIS
        Deterministic block number for an area+layer.
    .DESCRIPTION
        32_Blocks.Number wins when the sheet pins one. Otherwise it is derived from
        10_Project BlockNumberBase/Step so numbers are stable across rebuilds - block
        numbers matter in a safety project and must not shuffle when an area is added.
    #>
    param($Model, [string]$Area, [string]$Layer)
    $row = @($Model.Blocks | Where-Object { $_.Area -eq $Area -and $_.Layer -eq $Layer }) | Select-Object -First 1
    if ($row -and $row.Number) { return [int]$row.Number }
    $base = 500; $step = 10
    if ($Model.Project['BlockNumberBase']) { $base = [int]$Model.Project['BlockNumberBase'] }
    if ($Model.Project['BlockNumberStep']) { $step = [int]$Model.Project['BlockNumberStep'] }
    $offset = @{ 'Data' = 0; 'IOMap' = 1; 'Certified' = 2; 'Safety' = 3 }[$Layer]
    if ($null -eq $offset) { $offset = 4 }
    # System-wide block (v1.4): one block per layer, no area index to add.
    if (-not $Area) { return $base + $offset }
    $areas = @($Model.Stations | ForEach-Object { $_.Area })
    $i = [array]::IndexOf($areas, $Area)
    if ($i -lt 0) { throw "Area '$Area' is not in 20_Stations." }
    $base + ($i * $step) + $offset
}

function Get-TiaSheetAreaUdtRows {
    <#
    .SYNOPSIS
        Build the generated Area UDTs: one type per area, one member per device.
    .DESCRIPTION
        v1.4 replaces the 16 per-area F-DBs with 16 generated UDTs instantiated in one
        system F-DB. These rows are shaped exactly like 30_UDTs rows so they flow through
        the same ordering, F-compliance check and XML emitter as the authored types.

        Since v1.8 these types are AUTHORED in 30_UDTs and this generator is the fallback
        for a sheet that predates that - authored rows always win. A device is a member of
        its area's UDT, so the type row already carries the name, type and description.

        Every area also carries Area_Reset / Interlocks_OK / Area_Safe. The certified calls
        acknowledge against Area_Reset and the safety layer writes the other two, so without
        them every ACK pin compiles to "Tag ... not defined".
    #>
    param($Model)
    $pattern = $Model.Project['AreaUdtPattern']
    if (-not $pattern) { $pattern = 'UDT_Area_{Area}' }
    $udtNames = @($Model.Udts | ForEach-Object { $_.UDT } | Select-Object -Unique)

    # AUTHORED WINS. When 30_UDTs already declares the area types, they are the design and
    # nothing here invents one - that is the whole point of making them explicit, and it is
    # what lets Area_Reset / Interlocks_OK / Area_Safe stop being constants buried in code.
    # Generation below stays only as the migration path for a sheet that predates this.
    $authored = @($Model.Udts | Where-Object {
        $_.UDT -like ($pattern -replace '\{Area\}', '*')
    })
    if ($authored.Count) { return $authored }

    $rows = @()
    foreach ($z in $Model.Stations) {
        $devs = @($Model.DevicesByArea[$z.Area] | Where-Object { $_ })
        if (-not $devs.Count) { continue }
        $name = Expand-TiaSheetPattern -Pattern $pattern -Values @{ Area = $z.Area }
        $order = 1; $seen = @{}
        foreach ($d in ($devs | Sort-Object Device)) {
            if (-not $d.UDT) { throw "30_UDTs $($d.DeviceID): no UDT" }
            if ($udtNames -notcontains $d.UDT) { throw "30_UDTs $($d.DeviceID): UDT '$($d.UDT)' is not in 30_UDTs" }
            if ($seen.ContainsKey($d.Device)) {
                throw ("30_UDTs: area $($z.Area) has two devices named '$($d.Device)' " +
                       "($($seen[$d.Device]) and $($d.DeviceID)) - they would collide as members of $name")
            }
            $seen[$d.Device] = $d.DeviceID
            $rows += [pscustomobject]@{ UDT = $name; Order = $order; Member = $d.Device
                                        Datatype = $d.UDT; Comment = $d.Description; FailsafeCompliant = 'Yes' }
            $order++
        }
        foreach ($m in @(
            @{ n = 'Area_Reset';    c = 'area acknowledge / reset (supervised source)' },
            @{ n = 'Interlocks_OK'; c = 'all interlock contributors safe' },
            @{ n = 'Area_Safe';     c = 'area safe summary' })) {
            if ($seen.ContainsKey($m.n)) { continue }
            $rows += [pscustomobject]@{ UDT = $name; Order = $order; Member = $m.n
                                        Datatype = 'Bool'; Comment = $m.c; FailsafeCompliant = 'Yes' }
            $order++
        }
    }
    $rows
}

function Get-TiaSheetChannelPlan {
    <#
    .SYNOPSIS
        Resolve every safety channel to a tag name, live address and DB member path.
    .DESCRIPTION
        Address = the module's InputBase (read back from the hardware build) + the channel
        bit. Only BYTE 0 of an F-DI range carries the 8 safe channel values; the remaining
        6 bytes are diagnostics, so a channel index above 7 is a design error, not an
        address to compute.
    #>
    param($Model, [string]$AddressMapPath)

    if (-not (Test-Path $AddressMapPath)) {
        throw ("No address map at $AddressMapPath - run -Phase Hardware first. Addresses are " +
               "assigned by TIA and read back; they are never authored in the sheet.")
    }
    $addr = @{}
    foreach ($r in (Import-Csv $AddressMapPath)) { $addr["$($r.Area)/$($r.Module)"] = $r }

    $tagPattern = $Model.Project['TagPattern']
    if (-not $tagPattern) { $tagPattern = '{InputType}SRPPS_{Area}_{Device}_{Component}_{Signal}' }

    # {InputType} states a channel's safety class (fi/fo/ni/no) and comes from the Kind of
    # the module it is wired to - never from the sheet, where it could disagree with the rack.
    $modKind = @{}
    foreach ($m in $Model.Modules) { $modKind["$($m.Area)/$($m.ModuleName)"] = $m.Kind }

    # Every member path is rooted at the ONE system F-DB, with the area as the first level:
    # DB_SR_PPS.BTA.SE0101.EMO.ChA. Callers use .Db as that root, so an area-level member is
    # "$Db.Interlocks_OK" exactly as it was when each area had its own DB.
    $dbName = $Model.Project['DbPattern']
    if (-not $dbName) { $dbName = 'DB_SR_PPS' }

    # The Component level exists in the DB path ONLY when the device's UDT actually nests
    # it (UDT_SCB has EMO/KeySwitch members; a plain UDT_SafeInput has ChA/ChB directly).
    # Emitting CH10.KeySwitch.ChB against a UDT_SafeInput compiles to "Tag not defined".
    $udtMembers = @{}
    foreach ($u in $Model.Udts) {
        if (-not $udtMembers.ContainsKey($u.UDT)) { $udtMembers[$u.UDT] = @{} }
        $udtMembers[$u.UDT][$u.Member] = $true
    }

    $plan = @(); $problems = @()
    foreach ($c in $Model.Channels) {
        if ($c.Signal -eq 'Diag') { continue }
        $d = $Model.DeviceById[$c.DeviceID]
        if (-not $d) { $problems += "23_Channels $($c.ChannelID): unknown DeviceID"; continue }
        $key = "$($d.Area)/$($c.ModuleName)"
        if (-not $addr.ContainsKey($key)) { $problems += "23_Channels $($c.ChannelID): module $key not in the address map"; continue }
        $base = $addr[$key].InputBase
        if ([string]::IsNullOrWhiteSpace($base)) { $problems += "23_Channels $($c.ChannelID): module $key has no input address"; continue }
        $bit = 0
        if (-not [int]::TryParse([string]$c.Channel, [ref]$bit)) { $problems += "23_Channels $($c.ChannelID): Channel '$($c.Channel)' is not an integer"; continue }
        if ($bit -lt 0 -or $bit -gt 7) {
            $problems += "23_Channels $($c.ChannelID): channel $bit is outside byte 0 - only the first F-DI byte carries safe channel values"
            continue
        }
        $nests = ($d.UDT -and $udtMembers.ContainsKey($d.UDT) -and
                  $c.Component -and $udtMembers[$d.UDT].ContainsKey($c.Component))
        $comp = if ($nests) { $c.Component } else { '' }
        $itype = Get-TiaModuleInputType -Kind $modKind[$key]
        if (-not $itype) {
            $problems += "23_Channels $($c.ChannelID): module $key has Kind '$($modKind[$key])' - no fi/fo/ni/no class for the tag name"
            continue
        }
        $plan += [pscustomobject]@{
            ChannelID = $c.ChannelID
            Area      = $d.Area
            TagName   = (Expand-TiaSheetPattern -Pattern $tagPattern -Values @{
                            InputType = $itype; Area = $d.Area; Device = $d.Device
                            Component = $c.Component; Signal = $c.Signal })
            Address   = "%I$([int]$base).$bit"
            Member    = (@($d.Device, $comp, $c.Signal) | Where-Object { $_ }) -join '.'
            Db        = "$dbName.$($d.Area)"
            InputType = $itype
            Invert    = $(if ($c.Invert -eq 'Yes') { 'Yes' } else { 'No' })
            Verified  = $c.Verified
            Paired    = $c.Paired
            Component = $c.Component
            DeviceID  = $c.DeviceID
            Comment   = $c.Description
        }
    }
    if ($problems.Count) {
        foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Red }
        throw "Channel plan has $($problems.Count) problem(s)."
    }

    # two signals on one address is a wiring/design fault that the compiler will not catch
    $byAddr = @{}
    foreach ($p in $plan) {
        if ($byAddr.ContainsKey($p.Address)) {
            throw "23_Channels: $($p.ChannelID) and $($byAddr[$p.Address]) both map to $($p.Address)"
        }
        $byAddr[$p.Address] = $p.ChannelID
    }
    $plan
}

function Invoke-TiaSheetTagPhase {
    <#
    .SYNOPSIS
        Phase 4 (Tags): PLC tags at the addresses TIA assigned.
    .DESCRIPTION
        In  : 23_Channels, 21_Modules, reports/90_AddressMap.csv
        Out : tags in 10_Project.TagTableIn, plus reports/91_TagList.csv
    #>
    param($Model, [string]$ProjectPath, [string]$AddressMapPath, [string]$ReportDir, [switch]$Save)

    $plan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath
    $table = $Model.Project['TagTableIn']
    if (-not $table) { $table = 'FTags_In' }
    Write-Host ("tags: {0} channel(s) -> tag table '{1}'" -f $plan.Count, $table)

    $made = 0; $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        $existing = @()
        try { $existing = @(Get-TiaTagTable | ForEach-Object { $_.Name }) } catch { }
        if ($existing -notcontains $table) { New-TiaTagTable -Name $table | Out-Null }
        $have = @{}
        try { foreach ($t in (Get-TiaTag -TagTable $table)) { $have[$t.Name] = $true } } catch { }

        foreach ($p in $plan) {
            if ($have.ContainsKey($p.TagName)) { continue }
            New-TiaTag -Name $p.TagName -DataType 'Bool' -Address $p.Address -TagTable $table -Comment $p.Comment | Out-Null
            $have[$p.TagName] = $true
            $made++
        }
        Write-Host ("  {0} tag(s) created" -f $made)

        $plc = Get-TiaPlc | Select-Object -First 1
        $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
        try { $cErr = $compile.Errors } catch { }
        Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
        if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
    } finally {
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

    if (-not $ReportDir) { $ReportDir = Join-Path (Split-Path -Parent $ProjectPath) 'reports' }
    if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Force $ReportDir | Out-Null }
    $rp = Join-Path $ReportDir '91_TagList.csv'
    $plan | Select-Object Area, ChannelID, TagName, Address, Db, Member, Invert |
        Export-Csv -Path $rp -NoTypeInformation -Encoding ASCII
    Write-Host ("tag list -> {0}" -f $rp)

    [pscustomobject]@{
        Ok = ($cErr -eq 0); Phase = 'Tags'; ProjectPath = $ProjectPath
        Channels = $plan.Count; Created = $made; TagTable = $table; Report = $rp
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}

function Invoke-TiaSheetIOMapPhase {
    <#
    .SYNOPSIS
        Phase 5 (IOMap): FB_<area>_IOMap copying each channel tag into its DB member.
    .DESCRIPTION
        In  : 23_Channels (Invert, Paired), 30_UDTs, reports/90_AddressMap.csv
        Out : FB_<area>_IOMap (F_LAD), one network per device/component

        SIGNAL SENSE. The project convention is fail-safe: at the PLC input 1 = OK and
        0 = fault, so a channel maps straight through and everything downstream reads
        "1 = safe". Invert=Yes marks a device wired against that convention and emits a
        NEGATED contact.

        The rung compiles either way, so a wrong sense is invisible to the compiler and
        inverts a trip in the plant. Nothing here can detect that - only 23_Channels.Verified
        records that a person checked the drawing.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [string]$AddressMapPath,
          [switch]$Save)

    $plan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath

    $inverted = @($plan | Where-Object { $_.Invert -eq 'Yes' })
    Write-Host ("  signal sense: {0} fail-safe (direct), {1} inverted" -f
                ($plan.Count - $inverted.Count), $inverted.Count)
    foreach ($p in $inverted) { Write-Host ("    invert  {0}" -f $p.ChannelID) -ForegroundColor Yellow }
    $unverified = @($plan | Where-Object { $_.Verified -ne 'Yes' })
    if ($unverified.Count) {
        Write-Host ("  WARNING: {0} of {1} channel(s) are Verified<>Yes - their fail-safe sense is" -f $unverified.Count, $plan.Count) -ForegroundColor Yellow
        Write-Host  "  unconfirmed against the wiring drawings. This program is PROVISIONAL." -ForegroundColor Yellow
    }

    $fbPattern = $Model.Project['BlockPattern']
    if (-not $fbPattern) { $fbPattern = 'FB_{Layer}' }

    # ONE block for the whole system (v1.4), networks grouped by area so the block still
    # reads area by area.
    $units = @(); $id = 3; $nets = 0; $perArea = @()
    foreach ($z in $Model.Stations) {
        $rows = @($plan | Where-Object { $_.Area -eq $z.Area })
        if (-not $rows.Count) { continue }
        $n0 = $nets
        foreach ($g in ($rows | Group-Object DeviceID, Component)) {
            $b = New-TiaFlgBuilder
            foreach ($r in ($g.Group | Sort-Object Signal)) {
                # Invert=Yes => the field device is wired against the fail-safe convention,
                # so negate here and everything downstream still reads "1 = safe".
                Add-TiaFlgRung -Builder $b -From $r.TagName -To "$($r.Db).$($r.Member)" `
                               -Negated:($r.Invert -eq 'Yes') | Out-Null
            }
            $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title ("{0} {1}" -f $z.Area, ($g.Group[0].Member -split '\.')[0]))
            $id += 5
            $nets++
        }
        $perArea += [pscustomobject]@{ Area = $z.Area; Networks = ($nets - $n0) }
    }
    $name = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Layer = 'IOMap' }
    $num  = Get-TiaSheetBlockNumber -Model $Model -Area '' -Layer 'IOMap'
    $xml  = New-TiaFailsafeFbXml -Name $name -Number $num -CompileUnits $units
    Save-TiaMlDocument -Path (Join-Path $XmlDir "$name.xml") -Xml $xml | Out-Null
    $built = @([pscustomobject]@{ Name = $name; Number = $num; Networks = $units.Count })
    Write-Host ("iomap: {0} FB{1}, {2} network(s), {3} rung(s)" -f $name, $num, $nets, $plan.Count)
    foreach ($a in $perArea) { Write-Host ("  {0,-10} {1,3} networks" -f $a.Area, $a.Networks) }

    $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($b in $built) {
            Import-TiaBlockXml -Path (Join-Path $XmlDir "$($b.Name).xml") -Overwrite | Out-Null
        }
        $plc = Get-TiaPlc | Select-Object -First 1
        $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
        try { $cErr = $compile.Errors } catch { }
        Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
        if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
    } finally {
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

    [pscustomobject]@{
        Ok = ($cErr -eq 0); Phase = 'IOMap'; ProjectPath = $ProjectPath
        Blocks = @($built | ForEach-Object { $_.Name }); Networks = $nets; Rungs = $plan.Count
        Inverted = $inverted.Count
        Unverified = $unverified.Count
        Provisional = [bool]$unverified.Count
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}

function Get-TiaSheetCertifiedPlan {
    <#
    .SYNOPSIS
        Expand 31_Policy over the devices, honouring 33_SafetyBlocks overrides.
    #>
    param($Model, $ChannelPlan)

    $policy = @{}
    foreach ($r in $Model.SafetyBlocks) {
        # a per-device override replaces the whole policy chain for that device+component
        $k = "$($r.DeviceID)|$($r.Component)"
        if (-not $policy.ContainsKey($k)) { $policy[$k] = @() }
        $policy[$k] += $r
    }
    # Rules key on the device's UDT + Component, not on a DeviceType label. The UDT is the
    # structure the instruction chain writes into, so keying on it means a rule cannot be
    # matched to a device whose data has nowhere to put the result. DeviceType was free
    # text with no such guarantee.
    $byType = @{}
    foreach ($r in $Model.Policy) {
        $k = "$(([string]$r.UDT).Trim().Trim('"'))|$($r.Component)"
        if (-not $byType.ContainsKey($k)) { $byType[$k] = @() }
        $byType[$k] += $r
    }

    $groups = @{}
    foreach ($c in $ChannelPlan) {
        $k = "$($c.DeviceID)|$($c.Component)"
        if (-not $groups.ContainsKey($k)) { $groups[$k] = @() }
        $groups[$k] += $c
    }

    # With one Certified block for the whole system, an instance name must be unique across
    # ALL areas - Device is only unique within its area (CH10 exists in MCR and in BTA), so
    # {Area} has to be in the pattern or 149 statics collide down to a handful.
    $instPattern = $Model.Project['InstancePattern']
    if (-not $instPattern) { $instPattern = 'Inst_{Area}_{Device}_{Component}_{Instruction}' }

    $plan = @(); $missing = @()
    foreach ($k in ($groups.Keys | Sort-Object)) {
        $rows = $groups[$k]
        $did, $comp = $k -split '\|', 2
        $d = $Model.DeviceById[$did]
        $rules = if ($policy.ContainsKey($k)) { $policy[$k] } else { $byType["$($d.UDT)|$comp"] }
        if (-not $rules) { $missing += "no 31_Policy rule for UDT '$($d.UDT)' component '$comp' (e.g. $did)"; continue }

        $chA = @($rows | Where-Object { $_.Signal -eq 'ChA' -or $_.Member -like '*.ChA' }) | Select-Object -First 1
        $chB = @($rows | Where-Object { $_.Member -like '*.ChB' }) | Select-Object -First 1
        if (-not $chA) { $chA = $rows[0] }
        $base = ($rows[0].Member -split '\.'); $stem = if ($base.Count -gt 1) { ($base[0..($base.Count-2)] -join '.') } else { $base[0] }
        $dbStem = "$($rows[0].Db).$stem"

        foreach ($r in ($rules | Sort-Object { [int]$_.Order })) {
            if ($r.Instruction -eq 'EV1oo2DI' -and -not $chB) {
                $missing += "$did.$comp is single-channel but policy applies EV1oo2DI (needs ChA and ChB)"
                continue
            }
            $inst = if ($r.InstanceName) { $r.InstanceName } else {
                Expand-TiaSheetPattern -Pattern $instPattern -Values @{
                    Area = $d.Area; Device = $d.Device; Component = $comp; Instruction = $r.Instruction } }
            $plan += [pscustomobject]@{
                Area = $d.Area; DeviceID = $did; Device = $d.Device; Component = $comp
                DeviceUdt = $d.UDT
                Instruction = $r.Instruction; Version = $r.Version; Instance = $inst
                Order = [int]$r.Order
                ChA = $(if ($chA) { "$($rows[0].Db).$($chA.Member)" }); ChB = $(if ($chB) { "$($rows[0].Db).$($chB.Member)" })
                Stem = $dbStem
                AckSource = $(if ($r.AckSource) { Expand-TiaSheetPattern -Pattern $r.AckSource -Values @{ Db = $rows[0].Db; Area = $d.Area } })
                QTarget = $(if ($r.QTarget) { Expand-TiaSheetPattern -Pattern $r.QTarget -Values @{
                                Db = $rows[0].Db; Device = $d.Device; Component = $comp; Area = $d.Area } })
            }
        }
    }
    if ($missing.Count) {
        foreach ($m in $missing) { Write-Host "  $m" -ForegroundColor Red }
        throw "Certified plan has $($missing.Count) unresolved device(s)."
    }
    $plan
}

function Invoke-TiaSheetCertifiedPhase {
    <#
    .SYNOPSIS
        Phase 6 (Certified): ESTOP1 / SFDOOR / EV1oo2DI per 31_Policy.
    .DESCRIPTION
        In  : 31_Policy, 33_SafetyBlocks (overrides), 30_UDTs, 23_Channels
        Out : FB_<area>_Certified (F_LAD) with the instructions as multi-instance statics
        DISCTIME/TIME_DEL pins are left OPEN - the FlgNet importer rejects Time literals,
        so those safety parameters are set in TIA.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [string]$AddressMapPath,
          [switch]$Save)

    $chan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath
    $plan = Get-TiaSheetCertifiedPlan -Model $Model -ChannelPlan $chan
    $fbPattern = $Model.Project['BlockPattern']
    if (-not $fbPattern) { $fbPattern = 'FB_{Layer}' }

    # Which members each UDT actually has, and which type a device+component resolves to.
    # An output is only wired when its landing member exists, so adding a pin can never
    # create the dormant-member/undefined-tag pair of failures.
    $udtMembers = @{}; $udtMemberType = @{}
    foreach ($u in $Model.Udts) {
        if (-not $udtMembers.ContainsKey($u.UDT)) { $udtMembers[$u.UDT] = @{} }
        $udtMembers[$u.UDT][$u.Member] = $true
        $udtMemberType["$($u.UDT)|$($u.Member)"] = ([string]$u.Datatype).Trim().Trim('"')
    }
    function Resolve-StemType($deviceUdt, $component) {
        # a nested component carries its own type (UDT_SCB.EMO is a UDT_SafeInput);
        # otherwise the device's own type is the one that holds the members
        $t = $udtMemberType["$deviceUdt|$component"]
        if ($t -and $udtMembers.ContainsKey($t)) { return $t }
        $deviceUdt
    }

    # ONE Certified block for the whole system, networks grouped by area.
    $units = @(); $statics = @(); $id = 3; $perArea = @()
    foreach ($z in $Model.Stations) {
        $rows = @($plan | Where-Object { $_.Area -eq $z.Area })
        if (-not $rows.Count) { continue }
        $n0 = $units.Count; $s0 = $statics.Count
        foreach ($g in ($rows | Group-Object DeviceID, Component)) {
            $b = New-TiaFlgBuilder
            $prev1oo2 = $false
            $chain = @($g.Group | Sort-Object Order)
            for ($ci = 0; $ci -lt $chain.Count; $ci++) {
                $r = $chain[$ci]
                $isLast = ($ci -eq $chain.Count - 1)
                $statics += [pscustomobject]@{ Name = $r.Instance; Datatype = $r.Instruction }
                # Operand paths are derived from the channel plan's member stem, never from
                # a pattern: only the stem knows whether this device's UDT nests a Component
                # level, and a pattern that always inserts one yields "Tag not defined".
                $in = @{}; $out = @{}
                switch ($r.Instruction) {
                    'EV1oo2DI' { $in['IN1'] = $r.ChA; $in['IN2'] = $r.ChB; $in['ACK'] = $r.AckSource
                                 $out['Q'] = "$($r.Stem).Eval_OK"
                                 # only the 1oo2 evaluator produces a discrepancy fault
                                 if ($udtMembers[(Resolve-StemType $r.DeviceUdt $r.Component)]['Disc_Flt']) {
                                     $out['DISC_FLT'] = "$($r.Stem).Disc_Flt"
                                 } }
                    'SFDOOR'   { $in['IN1'] = $r.ChA; $in['IN2'] = $r.ChB; $in['ACK'] = $r.AckSource
                                 $out['Q'] = "$($r.Stem).Safe" }
                    # ESTOP1 follows the 1oo2 evaluator when policy chains them (D04), so it
                    # consumes the evaluated result rather than a raw channel.
                    'ESTOP1'   { $in['E_STOP'] = $(if ($prev1oo2) { "$($r.Stem).Eval_OK" } else { $r.ChA })
                                 $in['ACK'] = $r.AckSource
                                 $out['Q'] = "$($r.Stem).Safe"
                                 # stop category 1: only ESTOP1 has a delayed release, and
                                 # only some types declare somewhere to put it
                                 if ($udtMembers[(Resolve-StemType $r.DeviceUdt $r.Component)]['Safe_Delayed']) {
                                     $out['Q_DELAY'] = "$($r.Stem).Safe_Delayed"
                                 } }
                }
                # ACK_REQ and DIAG come from the LAST instruction in the chain only. Both
                # instructions of a chained pair produce them, and wiring both would drive
                # one coil from two networks - the operator acknowledges the terminal block,
                # so that is the one whose request and diagnostics are published.
                #
                # DIAG is a BYTE, and BYTE is not an F-compliant data type (Bool, Int,
                # Word, DInt, Time are). So DIAG cannot land in an F-DB at all - not as
                # Bool (type mismatch at the network) and not as Byte (rejected in the
                # F-UDT). It is deliberately non-safety-related service information;
                # Siemens intends it for a STANDARD DB. Until such a DB exists the pin
                # stays OpenCon - which is what omitting it from $out produces.
                if ($isLast) {
                    $stemType = Resolve-StemType $r.DeviceUdt $r.Component
                    if ($udtMembers[$stemType]['Ack_Req']) { $out['ACK_REQ'] = "$($r.Stem).Ack_Req" }
                    if ($udtMembers[$stemType]['Diag'])    { $out['DIAG']    = "$($r.Stem).Diag" }
                }
                $prev1oo2 = ($r.Instruction -eq 'EV1oo2DI')
                Add-TiaFlgCertifiedCall -Builder $b -Instruction $r.Instruction -InstanceName $r.Instance `
                                        -Inputs $in -Outputs $out -Version $r.Version | Out-Null
            }
            $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title "$($z.Area) $($g.Group[0].Device).$($g.Group[0].Component)")
            $id += 5
        }
        $perArea += [pscustomobject]@{ Area = $z.Area; Networks = ($units.Count - $n0); Instances = ($statics.Count - $s0) }
    }
    $name = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Layer = 'Certified' }
    $num  = Get-TiaSheetBlockNumber -Model $Model -Area '' -Layer 'Certified'
    $xml  = New-TiaFailsafeFbXml -Name $name -Number $num -CompileUnits $units -Statics $statics
    Save-TiaMlDocument -Path (Join-Path $XmlDir "$name.xml") -Xml $xml | Out-Null
    $built = @([pscustomobject]@{ Name = $name; Number = $num; Networks = $units.Count; Instances = $statics.Count })

    # A duplicate static would silently merge two devices onto one certified instance.
    $dupes = @($statics | Group-Object Name | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count) {
        foreach ($d in $dupes) { Write-Host "  duplicate instance '$($d.Name)' x$($d.Count)" -ForegroundColor Red }
        throw ("InstancePattern produces $($dupes.Count) duplicate instance name(s) across the system - " +
               "include {Area} in 10_Project.InstancePattern.")
    }
    Write-Host ("certified: {0} FB{1}, {2} network(s), {3} instruction call(s)" -f $name, $num, $units.Count, $plan.Count)
    foreach ($a in $perArea) { Write-Host ("  {0,-10} {1,3} networks {2,4} instances" -f $a.Area, $a.Networks, $a.Instances) }

    $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($b in $built) {
            Import-TiaBlockXml -Path (Join-Path $XmlDir "$($b.Name).xml") -Overwrite | Out-Null
        }
        $plc = Get-TiaPlc | Select-Object -First 1
        $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
        try { $cErr = $compile.Errors } catch { }
        Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
        if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
    } finally {
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

    [pscustomobject]@{
        Ok = ($cErr -eq 0); Phase = 'Certified'; ProjectPath = $ProjectPath
        Blocks = @($built | ForEach-Object { $_.Name }); Calls = $plan.Count
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}

function Invoke-TiaSheetSafetyPhase {
    <#
    .SYNOPSIS
        Phase 7 (Safety): area interlocks + the safety runtime that calls every area block.
    .DESCRIPTION
        In  : 34_Interlocks (a target x device matrix), 34_Exclusions, 30_UDTs, 31_Policy
        Out : FB_<area>_Safety (device summaries + the area AND), and the safety runtime FB
              calling IOMap -> Certified -> Safety per area, in that order.

        Device_Safe is COMPUTED here from each component's terminal certified output. It is
        not written anywhere else, so an interlock ANDing it directly would AND a member
        nothing ever sets - permanently false, which looks safe and is silently broken.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [string]$AddressMapPath,
          [switch]$Save)

    $chan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath
    $cert = Get-TiaSheetCertifiedPlan -Model $Model -ChannelPlan $chan

    # terminal member per device+component: the LAST instruction in the chain decides
    # whether the usable result is .Safe (ESTOP1/SFDOOR) or .1oo2_OK (EV1oo2DI alone)
    $terminal = @{}
    foreach ($g in ($cert | Group-Object DeviceID, Component)) {
        $last = @($g.Group | Sort-Object Order)[-1]
        $terminal["$($last.DeviceID)|$($last.Component)"] =
            $(if ($last.Instruction -eq 'EV1oo2DI') { "$($last.Stem).Eval_OK" } else { "$($last.Stem).Safe" })
    }

    # Which UDTs actually carry a Device_Safe summary. A single-component type does not
    # need one - its device result IS the component's terminal output, and computing an
    # AND of one term would be a second name for the same bit.
    $udtHasDeviceSafe = @{}
    foreach ($u in $Model.Udts) {
        if ($u.Member -eq 'Device_Safe') { $udtHasDeviceSafe[$u.UDT] = $true }
    }

    $fbPattern = $Model.Project['BlockPattern']
    if (-not $fbPattern) { $fbPattern = 'FB_{Layer}' }
    $dbName = $Model.Project['DbPattern']
    if (-not $dbName) { $dbName = 'DB_SR_PPS' }

    # ONE Interlocks block for the whole system: per-device summaries, then each area's AND,
    # then the system AND.
    $units = @(); $id = 3; $skippedAreas = @(); $perArea = @(); $areaSafes = @()
    foreach ($z in $Model.Stations) {
        $db = "$dbName.$($z.Area)"

        # One network per MULTI-component device: AND its components' terminal results into
        # Device_Safe. A single-component device contributes its terminal output directly -
        # $contrib records which, so 34_Interlocks never has to know a device's shape.
        $areaDevs = @(); $contrib = @{}
        foreach ($d in @($Model.DevicesByArea[$z.Area] | Sort-Object Device)) {
            $comps = @($terminal.Keys | Where-Object { $_ -like "$($d.DeviceID)|*" })
            if (-not $comps.Count) { continue }
            $srcs = @($comps | Sort-Object | ForEach-Object { $terminal[$_] })
            if ($udtHasDeviceSafe[$d.UDT]) {
                $b = New-TiaFlgBuilder
                Add-TiaFlgSeriesRung -Builder $b -From $srcs -To @("$db.$($d.Device).Device_Safe") | Out-Null
                $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title "$($z.Area) $($d.Device) Device_Safe")
                $id += 5
                $contrib[$d.DeviceID] = "$db.$($d.Device).Device_Safe"
            } else {
                # No summary member on this type, so more than one component would have
                # nowhere to AND into - that is a design error, not something to average away.
                if ($srcs.Count -gt 1) {
                    throw ("30_UDTs $($d.DeviceID): UDT '$($d.UDT)' has $($srcs.Count) components " +
                           "but no Device_Safe member to summarise them into.")
                }
                $contrib[$d.DeviceID] = $srcs[0]
            }
            $areaDevs += $d
        }

        # the area AND - only devices 34_Interlocks includes
        $inc = @($Model.Interlocks | Where-Object { $_.Area -eq $z.Area -and $_.Include -eq 'Yes' })
        $members = @()
        foreach ($i in $inc) {
            $d = $Model.DeviceById[$i.DeviceID]
            if (-not $d) { continue }
            if ($areaDevs -notcontains $d) { continue }   # no certified result to contribute
            $members += $contrib[$d.DeviceID]
        }
        if (-not $members.Count) { $skippedAreas += $z.Area; continue }
        $b = New-TiaFlgBuilder
        Add-TiaFlgSeriesRung -Builder $b -From $members -To @("$db.Interlocks_OK", "$db.Area_Safe") | Out-Null
        $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title "$($z.Area) Interlocks_OK")
        $id += 5
        $areaSafes += "$db.Area_Safe"
        $perArea += [pscustomobject]@{ Area = $z.Area; Devices = $areaDevs.Count; Contributors = $members.Count }
    }
    if (-not $perArea.Count) { throw "34_Interlocks produced no contributors - nothing to summate." }

    # the system summation: every area safe
    $b = New-TiaFlgBuilder
    Add-TiaFlgSeriesRung -Builder $b -From $areaSafes -To @("$dbName.System_Safe") | Out-Null
    $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title 'System_Safe')

    $name = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Layer = 'Safety' }
    $num  = Get-TiaSheetBlockNumber -Model $Model -Area '' -Layer 'Safety'
    $xml  = New-TiaFailsafeFbXml -Name $name -Number $num -CompileUnits $units
    Save-TiaMlDocument -Path (Join-Path $XmlDir "$name.xml") -Xml $xml | Out-Null
    $built = @([pscustomobject]@{ Name = $name; Number = $num; Networks = $units.Count })

    # the safety runtime: IOMap -> Certified -> Interlocks, once, in that order
    $rtName = $Model.Project['SafetyRuntimeFB']
    if (-not $rtName) { $rtName = 'Main_Safety_RTG1' }
    $rtUnits = @(); $rtStatics = @()
    $bu = New-TiaFlgBuilder
    foreach ($layer in @('IOMap','Certified','Safety')) {
        $blk = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Layer = $layer }
        $inst = "${blk}_Instance"
        $rtStatics += [pscustomobject]@{ Name = $inst; Datatype = $blk; Block = $true }
        Add-TiaFlgCall -Builder $bu -Block $blk -InstanceName $inst | Out-Null
    }
    $rtUnits += (New-TiaFlgCompileUnit -Builder $bu -Id 3 -Title 'SR_PPS')
    $rtNum = 1
    $rtRow = @($Model.Blocks | Where-Object { $_.Layer -eq 'Runtime' }) | Select-Object -First 1
    if ($rtRow -and $rtRow.Number) { $rtNum = [int]$rtRow.Number }
    $rtXml = New-TiaFailsafeFbXml -Name $rtName -Number $rtNum -CompileUnits $rtUnits -Statics $rtStatics
    Save-TiaMlDocument -Path (Join-Path $XmlDir "$rtName.xml") -Xml $rtXml | Out-Null

    Write-Host ("interlocks: {0} FB{1}, {2} network(s); runtime '{3}' calls {4} block(s)" -f
                $name, $num, $units.Count, $rtName, $rtStatics.Count)
    foreach ($a in $perArea) {
        Write-Host ("  {0,-10} {1,3} devices, {2,3} interlock contributors" -f $a.Area, $a.Devices, $a.Contributors)
    }
    if ($skippedAreas.Count) {
        Write-Host ("  areas with no interlock contributors: {0}" -f ($skippedAreas -join ', ')) -ForegroundColor Yellow
    }

    $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($b in $built) {
            Import-TiaBlockXml -Path (Join-Path $XmlDir "$($b.Name).xml") -Overwrite | Out-Null
        }
        Import-TiaBlockXml -Path (Join-Path $XmlDir "$rtName.xml") -Overwrite | Out-Null
        Write-Host ("  {0,-20} FB{1}" -f $rtName, $rtNum)

        $plc = Get-TiaPlc | Select-Object -First 1
        $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
        try { $cErr = $compile.Errors } catch { }
        Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
        if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
    } finally {
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

    [pscustomobject]@{
        Ok = ($cErr -eq 0); Phase = 'Interlocks'; ProjectPath = $ProjectPath
        Blocks = @($built | ForEach-Object { $_.Name }); Runtime = $rtName
        Areas = $perArea.Count
        Contributors = (@($perArea | ForEach-Object { $_.Contributors }) | Measure-Object -Sum).Sum
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}

function Invoke-TiaSheetDataPhase {
    <#
    .SYNOPSIS
        Phase 3 (Data): ONE system F-DB holding every area as a typed member.
    .DESCRIPTION
        In  : 30_UDTs (the area types and their device members), 32_Blocks
        Out : DB_SR_PPS as SW.Blocks.GlobalDB with ProgrammingLanguage F_DB, one member per
              area typed by that area's generated UDT (phase 2).
        Emitted as XML because ProgrammingLanguage=F_DB cannot be set from SCL - an
        SCL-created DB is an ordinary DB and the safety program will not accept it.

        The area UDT is what makes one DB workable: the whole system is browsable in one
        place, and a member path still reads DB_SR_PPS.BTA.SE0101.EMO.ChA.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [switch]$Save)

    $dbName = $Model.Project['DbPattern']
    if (-not $dbName) { $dbName = 'DB_SR_PPS' }
    $areaPattern = $Model.Project['AreaUdtPattern']
    if (-not $areaPattern) { $areaPattern = 'UDT_Area_{Area}' }

    # Reuse the same generator phase 2 created the types from, so the DB cannot instantiate
    # an area type that was never built (or miss one that was).
    $areaRows = @(Get-TiaSheetAreaUdtRows -Model $Model)
    $areaUdts = @($areaRows | ForEach-Object { $_.UDT } | Select-Object -Unique)

    $members = @(); $devTotal = 0
    foreach ($z in $Model.Stations) {
        $u = Expand-TiaSheetPattern -Pattern $areaPattern -Values @{ Area = $z.Area }
        if ($areaUdts -notcontains $u) { Write-Host "  $($z.Area): no devices - skipped"; continue }
        # @($null).Count is 1, not 0 - an area with no devices would inflate the total
        $n = @($Model.DevicesByArea[$z.Area] | Where-Object { $_ }).Count
        $devTotal += $n
        $members += [pscustomobject]@{ Name = $z.Area; Datatype = $u
                                       Comment = "$($z.Name) - $n device(s)" }
    }
    if (-not $members.Count) { throw "30_UDTs produced no DB members." }

    # System-level summary, computed by the safety phase from every area's Area_Safe.
    $members += [pscustomobject]@{ Name = 'System_Safe'; Datatype = 'Bool'
                                   Comment = 'every area safe (AND of Area_Safe)' }

    $number = Get-TiaSheetBlockNumber -Model $Model -Area '' -Layer 'Data'
    if (-not $XmlDir) { $XmlDir = Join-Path ([IO.Path]::GetTempPath()) ("tia-fdb-" + [guid]::NewGuid().ToString('n')) }
    $xml = New-TiaFailsafeDbXml -Name $dbName -Number $number -Members $members
    Save-TiaMlDocument -Path (Join-Path $XmlDir "$dbName.xml") -Xml $xml | Out-Null
    Write-Host ("data: {0} DB{1} with {2} area member(s) over {3} device(s) -> {4}" -f
                $dbName, $number, ($members.Count - 1), $devTotal, $XmlDir)

    $imported = @(); $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        Import-TiaBlockXml -Path (Join-Path $XmlDir "$dbName.xml") -Overwrite | Out-Null
        $imported += $dbName
        foreach ($m in $members) { Write-Host ("  {0,-14} {1}" -f $m.Name, $m.Datatype) }
        $plc = Get-TiaPlc | Select-Object -First 1
        $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
        try { $cErr = $compile.Errors } catch { }
        Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
        if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
    } finally {
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

    [pscustomobject]@{
        Ok = ($cErr -eq 0); Phase = 'Data'; ProjectPath = $ProjectPath
        Blocks = $imported; XmlDir = $XmlDir
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}

function Invoke-TiaSheetTypePhase {
    <#
    .SYNOPSIS
        Phase 2 (Types): create one PLC UDT per distinct 30_UDTs.UDT.
    .DESCRIPTION
        In  : 30_UDTs (UDT, Order, Member, Datatype, Comment, FailsafeCompliant)
        Out : PLC user data types, members in Order
        Types are created in dependency order so a UDT that nests another is never created
        first. Members that cannot live in a fail-safe block are rejected by name.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [switch]$Save)

    $authored = @($Model.Udts)
    if (-not $authored.Count) { throw "30_UDTs is empty - nothing to create." }
    # Area UDTs join the authored ones here so they share the dependency ordering and the
    # F-compliance check - an area type nests device types, so it must be created after
    # them, and Get-TiaUdtBuildOrder is what knows that.
    #
    # When the areas are authored in 30_UDTs, Get-TiaSheetAreaUdtRows hands those same rows
    # straight back - appending them would declare every member twice and TIA rejects the
    # import with "Element 'X' is not unique". So append only what 30_UDTs does not already
    # carry.
    $areaRows = @(Get-TiaSheetAreaUdtRows -Model $Model)
    $have = @{}
    foreach ($r in $authored) { $have["$($r.UDT)|$($r.Member)"] = $true }
    $areaRows = @($areaRows | Where-Object { -not $have.ContainsKey("$($_.UDT)|$($_.Member)") })
    $rows = $authored + $areaRows

    $names = @($rows | ForEach-Object { $_.UDT } | Select-Object -Unique)
    $bad = @()
    foreach ($r in $rows) {
        if (-not $r.Member)   { $bad += "30_UDTs $($r.UDT): a row has no Member"; continue }
        if (-not $r.Datatype) { $bad += "30_UDTs $($r.UDT).$($r.Member): no Datatype"; continue }
        if ($r.FailsafeCompliant -eq 'Yes' -and -not (Test-TiaFailsafeType -Datatype $r.Datatype -KnownUdts $names)) {
            $bad += "30_UDTs $($r.UDT).$($r.Member): '$($r.Datatype)' is not fail-safe compliant"
        }
    }
    if ($bad.Count) {
        foreach ($b in $bad) { Write-Host "  $b" -ForegroundColor Red }
        throw "30_UDTs has $($bad.Count) problem(s) - a non-F-compliant member would fail the safety compile."
    }

    if (-not $XmlDir) { $XmlDir = Join-Path ([IO.Path]::GetTempPath()) ('tia-udt-' + [guid]::NewGuid().ToString('n')) }
    $order = Get-TiaUdtBuildOrder -Rows $rows
    $genCount = @($areaRows | ForEach-Object { $_.UDT } | Select-Object -Unique).Count
    Write-Host ("types: {0} UDT(s) = {1} authored{2}" -f $order.Count,
                @($authored | ForEach-Object { $_.UDT } | Select-Object -Unique).Count,
                $(if ($genCount) { " + $genCount generated area type(s)" } else { ' (areas authored)' }))
    Write-Host ("  creation order: {0}" -f ($order -join ' -> '))

    $created = @(); $skipped = @(); $compile = $null; $cErr = 0
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        $existing = @()
        try { $existing = @(Get-TiaType | ForEach-Object { $_.Name }) } catch { }

        foreach ($u in $order) {
            $members = @($rows | Where-Object { $_.UDT -eq $u } | Sort-Object { [int]$_.Order })
            # Emitted as XML, not SCL: IsFailsafeCompliant cannot be set from SCL, and
            # without it every F-DB member using this type is rejected at the safety
            # compile with "not permitted in the fail-safe block interface".
            $fs = -not (@($members | Where-Object { $_.FailsafeCompliant -eq 'No' }).Count)
            $shaped = @($members | ForEach-Object {
                [pscustomobject]@{ Name = $_.Member; Datatype = $_.Datatype; Comment = $_.Comment }
            })
            $xml = New-TiaUdtXml -Name $u -Members $shaped -FailsafeCompliant $fs
            $f = Save-TiaMlDocument -Path (Join-Path $XmlDir "UDT_$u.xml") -Xml $xml
            Import-TiaTypeXml -Path $f -Overwrite | Out-Null
            if ($existing -contains $u) { $skipped += $u } else { $created += $u }
            Write-Host ("  {0,-16} {1,2} members  failsafe={2}" -f $u, $members.Count, $fs)
        }

        $plc = Get-TiaPlc | Select-Object -First 1
        $compile = Invoke-TiaCompile -Plc $plc.PlcSoftware
        try { $cErr = $compile.Errors } catch { }
        Write-Host ("compile: state={0} errors={1}" -f $compile.State, $cErr)
        if ($Save) { Save-TiaProject; Write-Host "saved: $ProjectPath" -ForegroundColor Green }
    } finally {
        # Always release the project. Leaving the Portal instance up holds a lock and the
        # next phase fails with "already been opened by user ... 2 minute delay".
        try { Disconnect-TiaPortal -Close | Out-Null } catch { }
    }

    [pscustomobject]@{
        Ok = ($cErr -eq 0); Phase = 'Types'; ProjectPath = $ProjectPath
        Created = $created; Skipped = $skipped
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}
