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
    param($Model, [string]$ProjectPath, [switch]$Save)

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

    $order = Get-TiaUdtBuildOrder -Rows $rows
    Write-Host ("types: {0} UDT(s), creation order: {1}" -f $order.Count, ($order -join ' -> '))

    $created = @(); $skipped = @(); $compile = $null; $cErr = 0
    $null = Open-TiaSheetProject -ProjectPath $ProjectPath
    try {
        $existing = @()
        try { $existing = @(Get-TiaType | ForEach-Object { $_.Name }) } catch { }

        foreach ($u in $order) {
            if ($existing -contains $u) { $skipped += $u; Write-Host "  $u already exists - skipped"; continue }
            $members = @($rows | Where-Object { $_.UDT -eq $u } | Sort-Object { [int]$_.Order })
            # ConvertTo-TiaUdtScl expects DataType/StartValue/Array; the sheet carries Datatype
            $shaped = @($members | ForEach-Object {
                [pscustomobject]@{ UDT = $u; Member = $_.Member; DataType = $_.Datatype
                                   Array = ''; StartValue = ''; Comment = $_.Comment }
            })
            $scl = ConvertTo-TiaUdtScl -Rows $shaped
            New-TiaType -Scl $scl | Out-Null
            $created += $u
            Write-Host ("  {0,-16} {1,2} members" -f $u, $members.Count)
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
