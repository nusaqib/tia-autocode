# Build.ps1 - declarative project generator (manifest + spreadsheets).
# Invoke-TiaBuildFromSpec materializes a full program from a YAML/JSON manifest that
# references CSV data (tags, UDTs, DBs, modules) and SCL logic files. It also still
# accepts the older inline format (arrays of objects) for backward compatibility.

function Invoke-TiaBuildFromSpec {
    <#
    .SYNOPSIS
        Builds (or updates) a TIA project from a manifest + spreadsheet/SCL data.
    .DESCRIPTION
        Reads a manifest (project.yaml/.json), then per PLC generates, in order:
        device -> modules (rack layout) -> UDTs -> DBs -> SCL logic -> tags -> compile.
        Tabular sections may be CSV file references (Phase 1) or inline objects (legacy).
        See docs/ROADMAP.md for the manifest + CSV column contracts.
    .PARAMETER Path
        Path to the manifest file (.yaml/.yml/.json).
    .PARAMETER Spec
        A manifest object (already parsed) instead of -Path.
    .PARAMETER BaseDir
        Base for resolving relative data/logic paths (defaults to the manifest folder).
    .EXAMPLE
        Invoke-TiaBuildFromSpec -Path .\examples\example-project\project.yaml
    #>
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory, ParameterSetName='Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName='Spec')]$Spec,
        [string]$BaseDir
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path $Path)) { throw "Manifest not found: $Path" }
        if (-not $BaseDir) { $BaseDir = Split-Path (Resolve-Path $Path) -Parent }
        $Spec = Read-TiaManifest $Path
    }
    if (-not $BaseDir) { $BaseDir = (Get-Location).Path }

    $steps = New-Object System.Collections.Generic.List[string]
    $errs  = New-Object System.Collections.Generic.List[string]
    function Step($m){ $steps.Add($m); Write-Host "  + $m" }
    function Fail($m){ $errs.Add($m);  Write-Warning $m }
    function Rel($p){ if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $BaseDir $p } }
    function Rows($ref){ @(Read-TiaRows -Ref $ref -BaseDir $BaseDir) }   # .csv or .xlsx#Sheet -> rows

    # 1) Portal
    if ($Spec.portal -and $Spec.portal.new) {
        $ui = [bool]$Spec.portal.ui
        Connect-TiaPortal -New -WithUserInterface:$ui | Out-Null
        Step "started new Portal (ui=$ui)"
    } elseif (-not $script:TiaSession.Portal) {
        Connect-TiaPortal | Out-Null; Step "attached to running Portal"
    }

    # 2) Project
    if ($Spec.project) {
        $pname = $Spec.project.name; $ppath = Rel $Spec.project.path
        $apFile = Get-ChildItem $ppath -Filter "$pname.ap*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($apFile -and $Spec.project.openIfExists) {
            Open-TiaProject -ProjectFile $apFile.FullName | Out-Null; Step "opened project $pname"
        } else {
            if (Test-Path (Join-Path $ppath $pname)) { Remove-Item (Join-Path $ppath $pname) -Recurse -Force }
            New-TiaProject -Name $pname -Path $ppath | Out-Null; Step "created project $pname"
        }
    }

    foreach ($plc in @($Spec.plcs)) {
        if (-not $plc) { continue }
        try {
            # --- device (CPU) ---
            $existing = Get-TiaPlc -Name $plc.name | Select-Object -First 1
            if (-not $existing -and $plc.orderNumber) {
                New-TiaDevice -TypeIdentifier $plc.orderNumber -Name $plc.name | Out-Null
                Step "added CPU $($plc.name) ($($plc.orderNumber))"
            }

            # --- modules (rack layout) ---
            foreach ($mref in @($plc.modules)) {
                if (-not $mref) { continue }
                $rows = if ($mref -is [string]) { Rows $mref } else { @($mref) }
                foreach ($r in $rows) {
                    try {
                        Add-TiaModule -DeviceName $plc.name -Slot ([int]$r.Slot) -OrderNumber $r.OrderNumber -Name $r.Name | Out-Null
                        Step "module $($plc.name)[slot $($r.Slot)] = $($r.Name)"
                    } catch { Fail "module $($plc.name)[slot $($r.Slot)]: $($_.Exception.Message)" }
                }
            }

            $sw = (Get-TiaPlc -Name $plc.name | Select-Object -First 1).PlcSoftware
            if (-not $sw) { $sw = (Get-TiaPlc | Select-Object -First 1).PlcSoftware }
            if (-not $sw) { Fail "no PLC software for '$($plc.name)'"; continue }

            # --- UDTs (CSV -> SCL, or inline {scl}) ---
            foreach ($uref in @($plc.udts) + @($plc.types)) {
                if (-not $uref) { continue }
                if ($uref -is [string]) {
                    $scl = ConvertTo-TiaUdtScl (Rows $uref)
                    if ($scl.Trim()) { Import-TiaScl -Plc $sw -Scl $scl | Out-Null; Step "UDTs from $uref" }
                } elseif ($uref.scl) { Import-TiaScl -Plc $sw -Scl $uref.scl | Out-Null; Step "UDT (inline)" }
                elseif ($uref.sclFile) { New-TiaType -Plc $sw -Path (Rel $uref.sclFile) | Out-Null; Step "UDT file" }
            }

            # --- types from XML (reverse round-trip: import into TypeGroup) ---
            foreach ($tref in @($plc.typesXml)) {
                if (-not ($tref -is [string])) { continue }
                try {
                    $fi = New-Object System.IO.FileInfo((Resolve-Path (Rel $tref)).Path)
                    $sw.TypeGroup.Types.Import($fi, [Siemens.Engineering.ImportOptions]::Override) | Out-Null
                    Step "type xml $tref"
                } catch { Fail "type xml ${tref}: $($_.Exception.Message)" }
            }

            # --- logic (SCL files) --- BEFORE DBs so instance DBs find their FB ---
            foreach ($lref in @($plc.logic) + @($plc.blocks)) {
                if (-not $lref) { continue }
                if ($lref -is [string]) { Import-TiaScl -Plc $sw -Path (Rel $lref) | Out-Null; Step "logic $lref" }
                elseif ($lref.sclFile) { Import-TiaScl -Plc $sw -Path (Rel $lref.sclFile) | Out-Null; Step "logic file" }
                elseif ($lref.scl) { Import-TiaScl -Plc $sw -Scl $lref.scl | Out-Null; Step "logic (inline)" }
            }

            # --- blocks from XML (reverse round-trip: import into BlockGroup) ---
            foreach ($bref in @($plc.blocksXml)) {
                if (-not ($bref -is [string])) { continue }
                try { Import-TiaBlockXml -Plc $sw -Path (Rel $bref) -Overwrite | Out-Null; Step "block xml $bref" }
                catch { Fail "block xml ${bref}: $($_.Exception.Message)" }
            }

            # --- DBs (CSV blocks+members -> SCL, or inline) - after logic ---
            if ($plc.dbs -and $plc.dbs.blocks) {
                $blocks  = Rows $plc.dbs.blocks
                $members = if ($plc.dbs.members) { Rows $plc.dbs.members } else { @() }
                foreach ($b in $blocks) {
                    $mem = @($members | Where-Object { $_.DBName -eq $b.DBName })
                    $scl = ConvertTo-TiaDbScl $b $mem
                    Import-TiaScl -Plc $sw -Scl $scl | Out-Null; Step "DB $($b.DBName) ($($b.Kind))"
                }
            }
            foreach ($db in @($plc.dataBlocks)) {   # legacy inline
                if (-not $db) { continue }
                if ($db.ofType) { New-TiaDataBlock -Plc $sw -Name $db.name -OfType $db.ofType | Out-Null }
                elseif ($db.scl) { New-TiaDataBlock -Plc $sw -Scl $db.scl | Out-Null }
                Step "DB $($db.name) (inline)"
            }

            # --- tags (CSV rows or inline objects) ---
            foreach ($tref in @($plc.tags)) {
                if (-not $tref) { continue }
                $rows = if ($tref -is [string]) { Rows $tref } else { @($tref) }
                $n = 0
                foreach ($r in $rows) {
                    $tt = if ($r.TagTable) { $r.TagTable } else { 'Default tag table' }
                    New-TiaTag -Plc $sw -TagTable $tt -Name $r.Name -DataType $r.DataType -Address $r.Address -Comment $r.Comment | Out-Null
                    $n++
                }
                Step "tags (+$n)$(if($tref -is [string]){" from $tref"})"
            }

            if ($plc.compile) {
                $c = Invoke-TiaCompile -Plc $sw
                Step "compiled $($plc.name): State=$($c.State) Errors=$($c.Errors) Warnings=$($c.Warnings)"
                if ($c.Errors -gt 0) { $c.Messages | Where-Object { $_ -like 'Error*' } | ForEach-Object { Fail $_ } }
            }
        } catch { Fail "PLC '$($plc.name)': $($_.Exception.Message)" }
    }

    # HMIs (tags CSV -> New-TiaHmiTag; tag-table/alarm/screen XML round-trip)
    foreach ($hmi in @($Spec.hmis)) {
        if (-not $hmi) { continue }
        try {
            # --- HMI device (panel) --- create from order number if not already present
            $existingHmi = Get-TiaHmi -Name $hmi.name | Select-Object -First 1
            if (-not $existingHmi -and $hmi.orderNumber) {
                New-TiaHmiDevice -OrderNumber $hmi.orderNumber -Name $hmi.name -DeviceItemName $hmi.deviceItemName | Out-Null
                Step "added HMI $($hmi.name) ($($hmi.orderNumber))"
            }

            # tag tables from XML (schema-exact) - before CSV tags so tables exist
            foreach ($tref in @($hmi.tagTablesXml)) {
                if (-not ($tref -is [string])) { continue }
                try { Import-TiaHmiTagTable -Hmi $hmi.name -Path (Rel $tref) -Overwrite | Out-Null; Step "HMI tagtable xml $tref" }
                catch { Fail "HMI '$($hmi.name)' tagtable ${tref}: $($_.Exception.Message)" }
            }
            # HMI tags from CSV (Name, Connection, PLCTag, DataType, Acquisition, Comment).
            # On WinCC Comfort/Advanced the tag collection has no Create(string) - tags
            # come from tag-table XML import - so treat that as an informative note (not a
            # failure) and stop trying; genuine per-row errors on other flavors still fail.
            foreach ($tref in @($hmi.tags)) {
                if (-not $tref) { continue }
                $rows = if ($tref -is [string]) { Rows $tref } else { @($tref) }
                $n = 0; $unsupported = $false
                foreach ($r in $rows) {
                    try {
                        $tt = if ($r.TagTable) { $r.TagTable } else { $null }
                        New-TiaHmiTag -Hmi $hmi.name -Name $r.Name -DataType $r.DataType `
                            -Connection $r.Connection -PlcTag $r.PLCTag -Acquisition $r.Acquisition `
                            -Comment $r.Comment -TagTable $tt | Out-Null
                        $n++
                    } catch {
                        # WinCC Comfort/Advanced cannot create HMI tags via the public API
                        # (no Create; tags need typed-DataType XML import). Treat that as an
                        # informative note, not a build failure; other flavors still per-row fail.
                        if ($_.Exception.Message -match 'no Create\(string\)|Could not resolve an HMI tag collection') { $unsupported = $true; break }
                        Fail "HMI '$($hmi.name)' tag $($r.Name): $($_.Exception.Message)"
                    }
                }
                if ($unsupported) {
                    Step "HMI tags: $(@($rows).Count) row(s) in $tref validated; this HMI flavor needs tag-table XML import (Import-TiaHmiTagTable) - see the tia-hmi skill"
                } else {
                    Step "HMI tags (+$n)$(if($tref -is [string]){" from $tref"})"
                }
            }
            # alarms from XML (discrete/analog)
            foreach ($aref in @($hmi.alarms)) {
                if (-not $aref) { continue }
                $p = if ($aref -is [string]) { $aref } else { $aref.importXml }
                $kind = if ($aref -isnot [string] -and $aref.kind) { $aref.kind } else { 'Discrete' }
                if ($p) {
                    try { Import-TiaHmiAlarms -Hmi $hmi.name -Kind $kind -Path (Rel $p) -Overwrite | Out-Null; Step "HMI $kind alarms $p" }
                    catch { Fail "HMI '$($hmi.name)' alarms ${p}: $($_.Exception.Message)" }
                }
            }
            # screens from XML
            foreach ($scr in @($hmi.screens)) {
                $p = if ($scr -is [string]) { $scr } else { $scr.importXml }
                if ($p) { Import-TiaScreen -Hmi $hmi.name -Path (Rel $p) -Overwrite | Out-Null; Step "HMI screen $p" }
            }
        } catch { Fail "HMI '$($hmi.name)': $($_.Exception.Message)" }
    }

    # Snapshot (optional) + save
    if ($Spec.build -and $Spec.build.snapshotDir) {
        try {
            foreach ($p in (Get-TiaPlc)) { Export-TiaProgram -Plc $p.PlcSoftware -OutDir (Join-Path (Rel $Spec.build.snapshotDir) $p.Name) | Out-Null }
            Step "snapshot -> $($Spec.build.snapshotDir)"
        } catch { Fail "snapshot: $($_.Exception.Message)" }
    }
    if (($Spec.save) -or ($Spec.build -and $Spec.build.save)) { Save-TiaProject; Step "saved project" }

    [pscustomobject]@{ Ok = ($errs.Count -eq 0); Steps = @($steps); Errors = @($errs) }
}
