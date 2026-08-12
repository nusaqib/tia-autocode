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
    Open-TiaProject -ProjectFile $file | Out-Null
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
