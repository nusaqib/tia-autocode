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
        Deterministic block number for a zone+layer.
    .DESCRIPTION
        32_Blocks.Number wins when the sheet pins one. Otherwise it is derived from
        10_Project BlockNumberBase/Step so numbers are stable across rebuilds - block
        numbers matter in a safety project and must not shuffle when a zone is added.
    #>
    param($Model, [string]$Zone, [string]$Layer)
    $row = @($Model.Blocks | Where-Object { $_.Zone -eq $Zone -and $_.Layer -eq $Layer }) | Select-Object -First 1
    if ($row -and $row.Number) { return [int]$row.Number }
    $base = 500; $step = 10
    if ($Model.Project['BlockNumberBase']) { $base = [int]$Model.Project['BlockNumberBase'] }
    if ($Model.Project['BlockNumberStep']) { $step = [int]$Model.Project['BlockNumberStep'] }
    $zones = @($Model.Zones | ForEach-Object { $_.Zone })
    $i = [array]::IndexOf($zones, $Zone)
    if ($i -lt 0) { throw "Zone '$Zone' is not in 20_Zones." }
    $offset = @{ 'Data' = 0; 'IOMap' = 1; 'Certified' = 2; 'Safety' = 3 }[$Layer]
    if ($null -eq $offset) { $offset = 4 }
    $base + ($i * $step) + $offset
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
    foreach ($r in (Import-Csv $AddressMapPath)) { $addr["$($r.Zone)/$($r.Module)"] = $r }

    $tagPattern = $Model.Project['TagPattern']
    if (-not $tagPattern) { $tagPattern = 'PPS_{Zone}_{DeviceRef}_{Component}_{Signal}' }

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
        $key = "$($d.Zone)/$($c.ModuleName)"
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
        $plan += [pscustomobject]@{
            ChannelID = $c.ChannelID
            Zone      = $d.Zone
            TagName   = (Expand-TiaSheetPattern -Pattern $tagPattern -Values @{
                            Zone = $d.Zone; DeviceRef = $d.DeviceRef; Component = $c.Component; Signal = $c.Signal })
            Address   = "%I$([int]$base).$bit"
            Member    = (@($d.DeviceRef, $comp, $c.Signal) | Where-Object { $_ }) -join '.'
            Db        = (Expand-TiaSheetPattern -Pattern $(if ($Model.Project['DbPattern']) { $Model.Project['DbPattern'] } else { 'DB_{Zone}' }) -Values @{ Zone = $d.Zone })
            Polarity  = $c.Polarity
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
    $plan | Select-Object Zone, ChannelID, TagName, Address, Db, Member, Polarity |
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
        Phase 5 (IOMap): FB_<zone>_IOMap copying each channel tag into its DB member.
    .DESCRIPTION
        In  : 23_Channels (Polarity, Paired), 22_Devices, reports/90_AddressMap.csv
        Out : FB_<zone>_IOMap (F_LAD), one network per device/component
        Polarity=NO emits a NEGATED contact. The rung compiles either way, so a wrong or
        guessed polarity is invisible to the compiler and inverts a trip in the plant -
        which is why a blank is an error unless -AssumeDefaultPolarity is given explicitly.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [string]$AddressMapPath,
          [switch]$AssumeDefaultPolarity, [switch]$Save)

    $plan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath
    $default = $Model.Project['DefaultPolarity']
    if (-not $default) { $default = 'NC' }

    $assumed = @($plan | Where-Object { -not $_.Polarity })
    if ($assumed.Count) {
        if (-not $AssumeDefaultPolarity) {
            throw ("$($assumed.Count) channel(s) have no Polarity. It is a wiring-drawing fact and " +
                   "is never defaulted silently - a wrong polarity inverts a trip. Fill 23_Channels, " +
                   "or pass -AssumeDefaultPolarity to build a PROVISIONAL, NON-RELEASABLE program " +
                   "using DefaultPolarity=$default.")
        }
        Write-Host ("  WARNING: assuming DefaultPolarity=$default on $($assumed.Count) channel(s)." ) -ForegroundColor Yellow
        Write-Host  "  This program is PROVISIONAL and must not be released until 23_Channels.Polarity" -ForegroundColor Yellow
        Write-Host  "  is confirmed against the wiring drawings." -ForegroundColor Yellow
        foreach ($p in $assumed) { $p.Polarity = $default }
    }

    $fbPattern = $Model.Project['BlockPattern']
    if (-not $fbPattern) { $fbPattern = 'FB_{Zone}_{Layer}' }

    $built = @(); $nets = 0
    foreach ($z in $Model.Zones) {
        $rows = @($plan | Where-Object { $_.Zone -eq $z.Zone })
        if (-not $rows.Count) { continue }
        $units = @(); $id = 3
        foreach ($g in ($rows | Group-Object DeviceID, Component)) {
            $b = New-TiaFlgBuilder
            foreach ($r in ($g.Group | Sort-Object Signal)) {
                # Polarity NO => the field contact is closed on demand, so invert it here
                # and everything downstream reads "1 = safe".
                Add-TiaFlgRung -Builder $b -From $r.TagName -To "$($r.Db).$($r.Member)" `
                               -Negated:($r.Polarity -eq 'NO') | Out-Null
            }
            $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title ($g.Group[0].Member -split '\.')[0])
            $id += 5
            $nets++
        }
        $name = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Zone = $z.Zone; Layer = 'IOMap' }
        $num  = Get-TiaSheetBlockNumber -Model $Model -Zone $z.Zone -Layer 'IOMap'
        $xml  = New-TiaFailsafeFbXml -Name $name -Number $num -CompileUnits $units
        Save-TiaMlDocument -Path (Join-Path $XmlDir "$name.xml") -Xml $xml | Out-Null
        $built += [pscustomobject]@{ Zone = $z.Zone; Name = $name; Number = $num; Networks = $units.Count }
    }
    Write-Host ("iomap: {0} block(s), {1} network(s), {2} rung(s)" -f $built.Count, $nets, $plan.Count)

    $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($b in $built) {
            Import-TiaBlockXml -Path (Join-Path $XmlDir "$($b.Name).xml") -Overwrite | Out-Null
            Write-Host ("  {0,-18} FB{1,-4} {2,2} networks" -f $b.Name, $b.Number, $b.Networks)
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
        AssumedPolarity = $assumed.Count
        Provisional = [bool]$assumed.Count
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
    $byType = @{}
    foreach ($r in $Model.Policy) {
        $k = "$($r.DeviceType)|$($r.Component)"
        if (-not $byType.ContainsKey($k)) { $byType[$k] = @() }
        $byType[$k] += $r
    }

    $groups = @{}
    foreach ($c in $ChannelPlan) {
        $k = "$($c.DeviceID)|$($c.Component)"
        if (-not $groups.ContainsKey($k)) { $groups[$k] = @() }
        $groups[$k] += $c
    }

    $instPattern = $Model.Project['InstancePattern']
    if (-not $instPattern) { $instPattern = 'Inst_{DeviceRef}_{Component}_{Instruction}' }

    $plan = @(); $missing = @()
    foreach ($k in ($groups.Keys | Sort-Object)) {
        $rows = $groups[$k]
        $did, $comp = $k -split '\|', 2
        $d = $Model.DeviceById[$did]
        $rules = if ($policy.ContainsKey($k)) { $policy[$k] } else { $byType["$($d.DeviceType)|$comp"] }
        if (-not $rules) { $missing += "no 31_Policy rule for DeviceType '$($d.DeviceType)' component '$comp' (e.g. $did)"; continue }

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
                    Zone = $d.Zone; DeviceRef = $d.DeviceRef; Component = $comp; Instruction = $r.Instruction } }
            $plan += [pscustomobject]@{
                Zone = $d.Zone; DeviceID = $did; DeviceRef = $d.DeviceRef; Component = $comp
                Instruction = $r.Instruction; Version = $r.Version; Instance = $inst
                Order = [int]$r.Order
                ChA = $(if ($chA) { "$($rows[0].Db).$($chA.Member)" }); ChB = $(if ($chB) { "$($rows[0].Db).$($chB.Member)" })
                Stem = $dbStem
                AckSource = $(if ($r.AckSource) { Expand-TiaSheetPattern -Pattern $r.AckSource -Values @{ Db = $rows[0].Db; Zone = $d.Zone } })
                QTarget = $(if ($r.QTarget) { Expand-TiaSheetPattern -Pattern $r.QTarget -Values @{
                                Db = $rows[0].Db; Device = $d.DeviceRef; Component = $comp; Zone = $d.Zone } })
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
        In  : 31_Policy, 33_SafetyBlocks (overrides), 22_Devices, 23_Channels
        Out : FB_<zone>_Certified (F_LAD) with the instructions as multi-instance statics
        DISCTIME/TIME_DEL pins are left OPEN - the FlgNet importer rejects Time literals,
        so those safety parameters are set in TIA.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [string]$AddressMapPath,
          [switch]$AssumeDefaultPolarity, [switch]$Save)

    $chan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath
    $plan = Get-TiaSheetCertifiedPlan -Model $Model -ChannelPlan $chan
    $fbPattern = $Model.Project['BlockPattern']
    if (-not $fbPattern) { $fbPattern = 'FB_{Zone}_{Layer}' }

    $built = @()
    foreach ($z in $Model.Zones) {
        $rows = @($plan | Where-Object { $_.Zone -eq $z.Zone })
        if (-not $rows.Count) { continue }
        $units = @(); $statics = @(); $id = 3
        foreach ($g in ($rows | Group-Object DeviceID, Component)) {
            $b = New-TiaFlgBuilder
            $prev1oo2 = $false
            foreach ($r in ($g.Group | Sort-Object Order)) {
                $statics += [pscustomobject]@{ Name = $r.Instance; Datatype = $r.Instruction }
                # Operand paths are derived from the channel plan's member stem, never from
                # a pattern: only the stem knows whether this device's UDT nests a Component
                # level, and a pattern that always inserts one yields "Tag not defined".
                $in = @{}; $out = @{}
                switch ($r.Instruction) {
                    'EV1oo2DI' { $in['IN1'] = $r.ChA; $in['IN2'] = $r.ChB; $in['ACK'] = $r.AckSource
                                 $out['Q'] = "$($r.Stem).1oo2_OK" }
                    'SFDOOR'   { $in['IN1'] = $r.ChA; $in['IN2'] = $r.ChB; $in['ACK'] = $r.AckSource
                                 $out['Q'] = "$($r.Stem).Safe" }
                    # ESTOP1 follows the 1oo2 evaluator when policy chains them (D04), so it
                    # consumes the evaluated result rather than a raw channel.
                    'ESTOP1'   { $in['E_STOP'] = $(if ($prev1oo2) { "$($r.Stem).1oo2_OK" } else { $r.ChA })
                                 $in['ACK'] = $r.AckSource
                                 $out['Q'] = "$($r.Stem).Safe" }
                }
                $prev1oo2 = ($r.Instruction -eq 'EV1oo2DI')
                Add-TiaFlgCertifiedCall -Builder $b -Instruction $r.Instruction -InstanceName $r.Instance `
                                        -Inputs $in -Outputs $out -Version $r.Version | Out-Null
            }
            $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title "$($g.Group[0].DeviceRef).$($g.Group[0].Component)")
            $id += 5
        }
        $name = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Zone = $z.Zone; Layer = 'Certified' }
        $num  = Get-TiaSheetBlockNumber -Model $Model -Zone $z.Zone -Layer 'Certified'
        $xml  = New-TiaFailsafeFbXml -Name $name -Number $num -CompileUnits $units -Statics $statics
        Save-TiaMlDocument -Path (Join-Path $XmlDir "$name.xml") -Xml $xml | Out-Null
        $built += [pscustomobject]@{ Zone = $z.Zone; Name = $name; Number = $num; Networks = $units.Count; Instances = $statics.Count }
    }
    Write-Host ("certified: {0} block(s), {1} instruction call(s)" -f $built.Count, $plan.Count)

    $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($b in $built) {
            Import-TiaBlockXml -Path (Join-Path $XmlDir "$($b.Name).xml") -Overwrite | Out-Null
            Write-Host ("  {0,-22} FB{1,-4} {2,2} networks {3,3} instances" -f $b.Name, $b.Number, $b.Networks, $b.Instances)
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
        Phase 7 (Safety): zone interlocks + the safety runtime that calls every zone block.
    .DESCRIPTION
        In  : 34_Interlocks (Target, DeviceID, Member, Include), 22_Devices, 31_Policy
        Out : FB_<zone>_Safety (device summaries + the zone AND), and the safety runtime FB
              calling IOMap -> Certified -> Safety per zone, in that order.

        Device_Safe is COMPUTED here from each component's terminal certified output. It is
        not written anywhere else, so an interlock ANDing it directly would AND a member
        nothing ever sets - permanently false, which looks safe and is silently broken.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [string]$AddressMapPath,
          [switch]$AssumeDefaultPolarity, [switch]$Save)

    $chan = Get-TiaSheetChannelPlan -Model $Model -AddressMapPath $AddressMapPath
    $cert = Get-TiaSheetCertifiedPlan -Model $Model -ChannelPlan $chan

    # terminal member per device+component: the LAST instruction in the chain decides
    # whether the usable result is .Safe (ESTOP1/SFDOOR) or .1oo2_OK (EV1oo2DI alone)
    $terminal = @{}
    foreach ($g in ($cert | Group-Object DeviceID, Component)) {
        $last = @($g.Group | Sort-Object Order)[-1]
        $terminal["$($last.DeviceID)|$($last.Component)"] =
            $(if ($last.Instruction -eq 'EV1oo2DI') { "$($last.Stem).1oo2_OK" } else { "$($last.Stem).Safe" })
    }

    $fbPattern = $Model.Project['BlockPattern']
    if (-not $fbPattern) { $fbPattern = 'FB_{Zone}_{Layer}' }
    $dbPattern = $Model.Project['DbPattern']
    if (-not $dbPattern) { $dbPattern = 'DB_{Zone}' }

    $built = @(); $skippedZones = @()
    foreach ($z in $Model.Zones) {
        $db = Expand-TiaSheetPattern -Pattern $dbPattern -Values @{ Zone = $z.Zone }
        $units = @(); $id = 3

        # one network per device: AND its components' terminal results into Device_Safe
        $zoneDevs = @()
        foreach ($d in @($Model.DevicesByZone[$z.Zone] | Sort-Object DeviceRef)) {
            $comps = @($terminal.Keys | Where-Object { $_ -like "$($d.DeviceID)|*" })
            if (-not $comps.Count) { continue }
            $srcs = @($comps | Sort-Object | ForEach-Object { $terminal[$_] })
            $b = New-TiaFlgBuilder
            Add-TiaFlgSeriesRung -Builder $b -From $srcs -To @("$db.$($d.DeviceRef).Device_Safe") | Out-Null
            $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title "$($d.DeviceRef) Device_Safe")
            $id += 5
            $zoneDevs += $d
        }

        # the zone AND - only devices 34_Interlocks includes
        $inc = @($Model.Interlocks | Where-Object { $_.Zone -eq $z.Zone -and $_.Include -eq 'Yes' })
        $members = @()
        foreach ($i in $inc) {
            $d = $Model.DeviceById[$i.DeviceID]
            if (-not $d) { continue }
            if ($zoneDevs -notcontains $d) { continue }   # no certified result to contribute
            $members += "$db.$($d.DeviceRef).Device_Safe"
        }
        if (-not $members.Count) { $skippedZones += $z.Zone; continue }
        $b = New-TiaFlgBuilder
        Add-TiaFlgSeriesRung -Builder $b -From $members -To @("$db.Interlocks_OK", "$db.Zone_Safe") | Out-Null
        $units += (New-TiaFlgCompileUnit -Builder $b -Id $id -Title "$($z.Zone) Interlocks_OK")

        $name = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Zone = $z.Zone; Layer = 'Safety' }
        $num  = Get-TiaSheetBlockNumber -Model $Model -Zone $z.Zone -Layer 'Safety'
        $xml  = New-TiaFailsafeFbXml -Name $name -Number $num -CompileUnits $units
        Save-TiaMlDocument -Path (Join-Path $XmlDir "$name.xml") -Xml $xml | Out-Null
        $built += [pscustomobject]@{ Zone = $z.Zone; Name = $name; Number = $num
                                     Devices = $zoneDevs.Count; Contributors = $members.Count }
    }

    # the safety runtime: one network per zone calling IOMap -> Certified -> Safety
    $rtName = $Model.Project['SafetyRuntimeFB']
    if (-not $rtName) { $rtName = 'Main_Safety_RTG1' }
    $rtUnits = @(); $rtStatics = @(); $rid = 3
    foreach ($b in $built) {
        $bu = New-TiaFlgBuilder
        foreach ($layer in @('IOMap','Certified','Safety')) {
            $blk = Expand-TiaSheetPattern -Pattern $fbPattern -Values @{ Zone = $b.Zone; Layer = $layer }
            $inst = "${blk}_Instance"
            $rtStatics += [pscustomobject]@{ Name = $inst; Datatype = $blk; Block = $true }
            Add-TiaFlgCall -Builder $bu -Block $blk -InstanceName $inst | Out-Null
        }
        $rtUnits += (New-TiaFlgCompileUnit -Builder $bu -Id $rid -Title "$($b.Zone)")
        $rid += 5
    }
    $rtNum = 1
    $rtRow = @($Model.Blocks | Where-Object { $_.Layer -eq 'Runtime' }) | Select-Object -First 1
    if ($rtRow -and $rtRow.Number) { $rtNum = [int]$rtRow.Number }
    $rtXml = New-TiaFailsafeFbXml -Name $rtName -Number $rtNum -CompileUnits $rtUnits -Statics $rtStatics
    Save-TiaMlDocument -Path (Join-Path $XmlDir "$rtName.xml") -Xml $rtXml | Out-Null

    Write-Host ("safety: {0} zone block(s), runtime '{1}' calling {2} block(s)" -f
                $built.Count, $rtName, $rtStatics.Count)
    if ($skippedZones.Count) {
        Write-Host ("  zones with no interlock contributors: {0}" -f ($skippedZones -join ', ')) -ForegroundColor Yellow
    }

    $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($b in $built) {
            Import-TiaBlockXml -Path (Join-Path $XmlDir "$($b.Name).xml") -Overwrite | Out-Null
            Write-Host ("  {0,-20} FB{1,-4} {2,2} devices, {3,2} interlock contributors" -f
                        $b.Name, $b.Number, $b.Devices, $b.Contributors)
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
        Ok = ($cErr -eq 0); Phase = 'Safety'; ProjectPath = $ProjectPath
        Blocks = @($built | ForEach-Object { $_.Name }); Runtime = $rtName
        Contributors = (@($built | ForEach-Object { $_.Contributors }) | Measure-Object -Sum).Sum
        CompileState = [string]$compile.State; CompileErrors = $cErr
    }
}

function Invoke-TiaSheetDataPhase {
    <#
    .SYNOPSIS
        Phase 3 (Data): one formal F-DB per zone, one member per device.
    .DESCRIPTION
        In  : 22_Devices (DeviceID, Zone, DeviceRef, UDT), 30_UDTs, 32_Blocks
        Out : DB_<zone> as SW.Blocks.GlobalDB with ProgrammingLanguage F_DB
        Emitted as XML because ProgrammingLanguage=F_DB cannot be set from SCL - an
        SCL-created DB is an ordinary DB and the safety program will not accept it.
    #>
    param($Model, [string]$ProjectPath, [string]$XmlDir, [switch]$Save)

    $dbPattern = $Model.Project['DbPattern']
    if (-not $dbPattern) { $dbPattern = 'DB_{Zone}' }
    $udtNames = @($Model.Udts | ForEach-Object { $_.UDT } | Select-Object -Unique)

    $plan = @()
    foreach ($z in $Model.Zones) {
        $devs = @($Model.DevicesByZone[$z.Zone])
        if (-not $devs.Count) { Write-Host "  $($z.Zone): no devices - skipped"; continue }
        $members = @()
        $seen = @{}
        foreach ($d in ($devs | Sort-Object DeviceRef)) {
            if (-not $d.UDT) { throw "22_Devices $($d.DeviceID): no UDT" }
            if ($udtNames -notcontains $d.UDT) { throw "22_Devices $($d.DeviceID): UDT '$($d.UDT)' is not in 30_UDTs" }
            $nm = $d.DeviceRef
            if ($seen.ContainsKey($nm)) {
                throw ("22_Devices: zone $($z.Zone) has two devices with DeviceRef '$nm' " +
                       "($($seen[$nm]) and $($d.DeviceID)) - they would collide as DB members")
            }
            $seen[$nm] = $d.DeviceID
            $members += [pscustomobject]@{ Name = $nm; Datatype = $d.UDT; Comment = $d.Description }
        }
        # Zone-level members. The certified calls acknowledge against Zone_Reset and the
        # safety layer writes Interlocks_OK / Zone_Safe, so without these every ACK pin
        # compiles to "Tag DB_<zone>.Zone_Reset not defined".
        foreach ($zm in @(
            @{ n = 'Zone_Reset';    c = 'zone acknowledge / reset (supervised source)' },
            @{ n = 'Interlocks_OK'; c = 'all interlock contributors safe' },
            @{ n = 'Zone_Safe';     c = 'zone safe summary' })) {
            if (-not $seen.ContainsKey($zm.n)) {
                $members += [pscustomobject]@{ Name = $zm.n; Datatype = 'Bool'; Comment = $zm.c }
            }
        }
        $plan += [pscustomobject]@{
            Zone = $z.Zone
            Name = (Expand-TiaSheetPattern -Pattern $dbPattern -Values @{ Zone = $z.Zone })
            Number = (Get-TiaSheetBlockNumber -Model $Model -Zone $z.Zone -Layer 'Data')
            Members = $members
        }
    }
    if (-not $plan.Count) { throw "22_Devices produced no DB members." }

    if (-not $XmlDir) { $XmlDir = Join-Path ([IO.Path]::GetTempPath()) ("tia-fdb-" + [guid]::NewGuid().ToString('n')) }
    $files = @()
    foreach ($p in $plan) {
        $xml = New-TiaFailsafeDbXml -Name $p.Name -Number $p.Number -Members $p.Members
        $files += (Save-TiaMlDocument -Path (Join-Path $XmlDir "$($p.Name).xml") -Xml $xml)
    }
    Write-Host ("data: {0} F-DB(s), {1} member(s) -> {2}" -f $plan.Count,
                (@($plan | ForEach-Object { $_.Members.Count }) | Measure-Object -Sum).Sum, $XmlDir)

    $imported = @(); $cErr = 0; $compile = $null
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        foreach ($p in $plan) {
            $f = Join-Path $XmlDir "$($p.Name).xml"
            Import-TiaBlockXml -Path $f -Overwrite | Out-Null
            $imported += $p.Name
            Write-Host ("  {0,-12} DB{1,-4} {2,2} members" -f $p.Name, $p.Number, $p.Members.Count)
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

    $rows = @($Model.Udts)
    if (-not $rows.Count) { throw "30_UDTs is empty - nothing to create." }

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
    Write-Host ("types: {0} UDT(s), creation order: {1}" -f $order.Count, ($order -join ' -> '))

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
