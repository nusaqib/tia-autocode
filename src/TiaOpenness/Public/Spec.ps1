# Spec.ps1 - offline validation of a tia-autocode project spec (Phase 0).
# Test-TiaSpec reads the manifest + CSV data and checks structure, references, and
# datatypes WITHOUT touching TIA Portal. Run it before every build (and in CI).
# (Primitive-type set + Test-TiaPrimitive live in Private/TiaSynth.ps1.)

function Test-TiaSpec {
    <#
    .SYNOPSIS
        Validates a project manifest + CSV data offline (no TIA connection needed).
    .DESCRIPTION
        Checks: referenced files exist; CSVs have required columns; tag addresses are
        well-formed; names are unique; UDT/FB references resolve; DB member and tag
        datatypes are primitives or defined UDTs. Returns { Ok, Errors, Warnings }.
    .PARAMETER Path
        Path to the manifest (.yaml/.yml/.json).
    .EXAMPLE
        Test-TiaSpec -Path .\examples\example-project\project.yaml
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $errors   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    function Err($m){ $errors.Add($m) }
    function Warn($m){ $warnings.Add($m) }

    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Ok=$false; Errors=@("Manifest not found: $Path"); Warnings=@() } }
    $base = Split-Path (Resolve-Path $Path) -Parent
    function Resolve-Rel($p){ if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $base $p } }

    try { $spec = Read-TiaManifest $Path } catch { return [pscustomobject]@{ Ok=$false; Errors=@("Manifest parse error: $($_.Exception.Message)"); Warnings=@() } }

    if (-not $spec.project -or -not $spec.project.name) { Err "project.name is required" }

    # Accepts a .csv path or an .xlsx[#Sheet] ref (both relative to the manifest folder).
    function Test-Columns($ref, $required, $label) {
        $path = Resolve-TiaRef $ref $base
        if (-not (Test-Path $path)) { Err "$label file not found: $path"; return $null }
        try { $rows = @(Read-TiaRows -Ref $ref -BaseDir $base) }
        catch { Err "$label ($([System.IO.Path]::GetFileName($path))): $($_.Exception.Message)"; return $null }
        if ($rows.Count -eq 0) { Warn "$label file is empty: $path"; return @() }
        $cols = $rows[0].PSObject.Properties.Name
        foreach ($rc in $required) {
            if ($cols -notcontains $rc) { Err "$label ($([System.IO.Path]::GetFileName($path))): missing required column '$rc'" }
        }
        return $rows
    }
    function Test-TypeRef($dt, $udtNames, $ctx) {
        if (-not $dt) { Err "${ctx}: empty DataType"; return }
        if (Test-TiaPrimitive $dt) { return }
        $clean = $dt.Trim().Trim('"').ToLowerInvariant()
        if ($udtNames -contains $clean) { return }
        Err "${ctx}: datatype '$dt' is neither a primitive nor a defined UDT"
    }

    foreach ($plc in @($spec.plcs)) {
        if (-not $plc) { continue }
        $pn = $plc.name
        if (-not $pn) { Err "a plc entry is missing 'name'" }

        # --- UDTs (collect defined names first, for reference checks) ---
        $udtNames = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($plc.udts)) {
            if (-not $u) { continue }
            $rows = Test-Columns $u @('UDT','Member','DataType') "UDT[$pn]"
            if ($null -eq $rows) { continue }
            foreach ($r in $rows) { if ($r.UDT) { [void]$udtNames.Add($r.UDT.Trim().ToLowerInvariant()) } }
        }
        $udtSet = @($udtNames | Select-Object -Unique)
        foreach ($u in @($plc.udts)) {
            if (-not $u) { continue }
            $rows = @(try { Read-TiaRows -Ref $u -BaseDir $base } catch { @() })
            foreach ($r in $rows) {
                if (-not $r.Member) { Err "UDT[$pn] $($r.UDT): row with empty Member" }
                Test-TypeRef $r.DataType $udtSet "UDT[$pn] $($r.UDT).$($r.Member)"
            }
        }

        # --- FBs defined in logic (for InstanceOfFB refs) ---
        $fbNames = New-Object System.Collections.Generic.List[string]
        foreach ($l in @($plc.logic)) {
            if (-not $l) { continue }
            $lp = Resolve-Rel $l
            if (-not (Test-Path $lp)) { Err "logic[$pn] file not found: $lp"; continue }
            $txt = Get-Content $lp -Raw
            foreach ($mm in [regex]::Matches($txt, '(?im)^\s*FUNCTION_BLOCK\s+"?([A-Za-z_]\w*)"?')) {
                [void]$fbNames.Add($mm.Groups[1].Value.ToLowerInvariant())
            }
        }
        $fbSet = @($fbNames | Select-Object -Unique)

        # --- Modules (rack layout) ---
        foreach ($mod in @($plc.modules)) {
            if (-not $mod) { continue }
            $rows = Test-Columns $mod @('Slot','OrderNumber','Name') "Modules[$pn]"
            if ($null -eq $rows) { continue }
            $slots = @{}
            foreach ($r in $rows) {
                if ("$($r.Slot)" -notmatch '^\d+$') { Err "Modules[$pn] $($r.Name): Slot '$($r.Slot)' must be an integer" }
                elseif ($slots.ContainsKey($r.Slot)) { Err "Modules[$pn]: duplicate Slot $($r.Slot)" } else { $slots[$r.Slot] = $true }
                if (-not $r.OrderNumber) { Err "Modules[$pn] $($r.Name): OrderNumber required" }
                if (-not $r.Name) { Err "Modules[$pn] slot $($r.Slot): Name required" }
            }
        }

        # --- Tags ---
        foreach ($t in @($plc.tags)) {
            if (-not $t) { continue }
            $rows = Test-Columns $t @('TagTable','Name','DataType','Address') "Tags[$pn]"
            if ($null -eq $rows) { continue }
            $seen = @{}
            foreach ($r in $rows) {
                $key = "$($r.TagTable)/$($r.Name)"
                if ($seen.ContainsKey($key)) { Err "Tags[$pn]: duplicate tag '$key'" } else { $seen[$key] = $true }
                if (-not $r.Address) { Err "Tags[$pn] ${key}: Address is required (explicit addressing)" }
                elseif ($r.Address -notmatch '^%[A-Za-z]+\d+(\.\d+)?$' -and $r.Address -notmatch '^%DB\d+\.') {
                    Err "Tags[$pn] ${key}: malformed address '$($r.Address)'"
                }
                Test-TypeRef $r.DataType $udtSet "Tags[$pn] $key"
            }
        }

        # --- DBs ---
        $dbNames = @{}
        if ($plc.dbs -and $plc.dbs.blocks) {
            $rows = Test-Columns $plc.dbs.blocks @('DBName','Kind') "DBs[$pn]"
            if ($rows) {
                foreach ($r in $rows) {
                    if (-not $r.DBName) { Err "DBs[$pn]: row with empty DBName"; continue }
                    $dbNames[$r.DBName] = $r.Kind
                    $kind = "$($r.Kind)".Trim()
                    if ($kind -notin 'Global','InstanceOfFB','TypedOfUDT') { Err "DBs[$pn] $($r.DBName): invalid Kind '$kind'" }
                    if ($kind -in 'InstanceOfFB','TypedOfUDT') {
                        if (-not $r.OfType) { Err "DBs[$pn] $($r.DBName): Kind '$kind' requires OfType" }
                        elseif ($kind -eq 'InstanceOfFB' -and ($fbSet -notcontains $r.OfType.Trim().ToLowerInvariant())) {
                            Err "DBs[$pn] $($r.DBName): OfType FB '$($r.OfType)' not found in logic/"
                        }
                        elseif ($kind -eq 'TypedOfUDT' -and ($udtSet -notcontains $r.OfType.Trim().ToLowerInvariant())) {
                            Err "DBs[$pn] $($r.DBName): OfType UDT '$($r.OfType)' not defined"
                        }
                    }
                }
            }
        }
        if ($plc.dbs -and $plc.dbs.members) {
            $rows = Test-Columns $plc.dbs.members @('DBName','Member','DataType') "DBMembers[$pn]"
            if ($rows) {
                foreach ($r in $rows) {
                    if ($dbNames.Count -and -not $dbNames.ContainsKey($r.DBName)) {
                        Warn "DBMembers[$pn]: member '$($r.Member)' targets DB '$($r.DBName)' not listed in dbs.blocks"
                    } elseif ($dbNames.ContainsKey($r.DBName) -and $dbNames[$r.DBName] -ne 'Global') {
                        Warn "DBMembers[$pn]: DB '$($r.DBName)' is $($dbNames[$r.DBName]); members only apply to Global DBs"
                    }
                    Test-TypeRef $r.DataType $udtSet "DBMembers[$pn] $($r.DBName).$($r.Member)"
                }
            }
        }
    }

    # --- HMIs (Phase 3) ---
    foreach ($hmi in @($spec.hmis)) {
        if (-not $hmi) { continue }
        $hn = $hmi.name
        if (-not $hn) { Err "an hmi entry is missing 'name'" }
        if ($hmi.orderNumber) {
            $ord = "$($hmi.orderNumber)" -replace '^OrderNumber:',''
            # MLFB like 6AV2 124-1GC01-0AX0/17.0.0.0 (panel image version required)
            if ($ord -notmatch '^6AV\d.*/\d+(\.\d+)*$') {
                Warn "HMI[$hn]: orderNumber '$($hmi.orderNumber)' does not look like '6AV... /<version>' (panel image version required)"
            }
        }
        foreach ($t in @($hmi.tags)) {
            if (-not ($t -is [string])) { continue }
            $rows = Test-Columns $t @('Name','DataType') "HMITags[$hn]"
            if ($null -eq $rows) { continue }
            $seen = @{}
            foreach ($r in $rows) {
                $key = if ($r.TagTable) { "$($r.TagTable)/$($r.Name)" } else { $r.Name }
                if ($seen.ContainsKey($key)) { Err "HMITags[$hn]: duplicate tag '$key'" } else { $seen[$key] = $true }
                if (-not $r.DataType) { Err "HMITags[$hn] $($r.Name): DataType is required" }
                # External tag (has a Connection) should name its source PLC tag.
                if ($r.Connection -and -not $r.PLCTag) { Warn "HMITags[$hn] $($r.Name): Connection set but no PLCTag" }
            }
        }
        foreach ($x in @($hmi.tagTablesXml)) { if ($x -is [string] -and -not (Test-Path (Resolve-Rel $x))) { Err "HMI[$hn] tagTablesXml not found: $x" } }
        foreach ($a in @($hmi.alarms)) {
            $p = if ($a -is [string]) { $a } else { $a.importXml }
            if ($p -and -not (Test-Path (Resolve-Rel $p))) { Err "HMI[$hn] alarms XML not found: $p" }
        }
        foreach ($s in @($hmi.screens)) {
            $p = if ($s -is [string]) { $s } else { $s.importXml }
            if ($p -and -not (Test-Path (Resolve-Rel $p))) { Err "HMI[$hn] screen XML not found: $p" }
        }
    }

    [pscustomobject]@{
        Ok       = ($errors.Count -eq 0)
        Errors   = @($errors)
        Warnings = @($warnings)
        Summary  = "Errors: $($errors.Count), Warnings: $($warnings.Count)"
    }
}
