# Naming.ps1 - naming-convention lint for a tia-autocode spec (Phase 4).
# Test-TiaNaming reads the object names a spec would create (tags, UDTs, DBs, FBs/FCs,
# HMI tags, modules) and checks them against configurable rules - pattern / prefix /
# suffix / maxLength / case. Offline (no TIA). Advisory by default: Test-TiaSpec folds
# any violations into its Warnings.

function Test-TiaNaming {
    <#
    .SYNOPSIS
        Lints object names in a spec against naming-convention rules (offline).
    .DESCRIPTION
        Rules come from the manifest's `naming:` section, or a separate rules file passed
        via -Rules (.yaml/.yml/.json), or a hashtable. Each object kind (tags, udts, dbs,
        fbs, fcs, hmiTags, modules) may set: pattern (regex), prefix, suffix, maxLength,
        and case (Pascal|camel|UPPER|lower|snake). Only kinds with a rule are checked.
        Returns { Ok, Violations, Summary }. Ok is true when there are no violations.
    .PARAMETER Path
        Path to the manifest (.yaml/.yml/.json).
    .PARAMETER Rules
        Optional override ruleset: a path to a rules file, or a hashtable/object of rules.
        When omitted, the manifest's `naming:` section is used.
    .EXAMPLE
        Test-TiaNaming -Path .\project.yaml
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, $Rules)

    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Ok=$false; Violations=@("Manifest not found: $Path"); Summary='1 problem' } }
    $base = Split-Path (Resolve-Path $Path) -Parent
    $spec = Read-TiaManifest $Path

    # Resolve the ruleset.
    $ruleSet = $null
    if ($null -ne $Rules) {
        if ($Rules -is [string]) { $ruleSet = Read-TiaManifest $Rules }
        else { $ruleSet = $Rules }
    } elseif ($spec.naming) { $ruleSet = $spec.naming }   # manifest object is an IDictionary; dot-access works

    $violations = New-Object System.Collections.Generic.List[string]
    if (-not $ruleSet) {
        return [pscustomobject]@{ Ok=$true; Violations=@(); Summary='no naming rules defined (nothing to lint)' }
    }

    # Manifest objects are IDictionary (OrderedDictionary); -Rules may be a hashtable.
    function Get-Rule($kind) {
        if ($ruleSet -is [System.Collections.IDictionary]) { if ($ruleSet.Contains($kind)) { return $ruleSet[$kind] } return $null }
        $p = $ruleSet.PSObject.Properties[$kind]; if ($p) { return $p.Value } return $null
    }
    function Prop($obj, $name) {
        if ($null -eq $obj) { return $null }
        if ($obj -is [System.Collections.IDictionary]) { if ($obj.Contains($name)) { return $obj[$name] } return $null }
        $p = $obj.PSObject.Properties[$name]; if ($p) { return $p.Value } return $null
    }
    $caseRegex = @{
        'pascal' = '^[A-Z][A-Za-z0-9]*$'
        'camel'  = '^[a-z][A-Za-z0-9]*$'
        'upper'  = '^[A-Z0-9_]+$'
        'lower'  = '^[a-z0-9_]+$'
        'snake'  = '^[a-z0-9]+(_[a-z0-9]+)*$'
    }
    function Check($name, $rule, $kind) {
        if (-not $name) { return }
        $fails = @()
        # Case-SENSITIVE matching (PowerShell -match is case-insensitive; naming needs case).
        $pat = Prop $rule 'pattern'; if ($pat -and -not [regex]::IsMatch($name, $pat)) { $fails += "does not match pattern '$pat'" }
        $pre = Prop $rule 'prefix';  if ($pre -and -not $name.StartsWith($pre, [System.StringComparison]::Ordinal)) { $fails += "missing prefix '$pre'" }
        $suf = Prop $rule 'suffix';  if ($suf -and -not $name.EndsWith($suf, [System.StringComparison]::Ordinal))   { $fails += "missing suffix '$suf'" }
        $max = Prop $rule 'maxLength'; if ($max -and $name.Length -gt [int]$max) { $fails += "exceeds maxLength $max ($($name.Length))" }
        $case = Prop $rule 'case'
        if ($case) {
            $ck = "$case".ToLowerInvariant()
            if ($caseRegex.ContainsKey($ck) -and -not [regex]::IsMatch($name, $caseRegex[$ck])) { $fails += "not $case-case" }
        }
        foreach ($f in $fails) { [void]$violations.Add("${kind}: '$name' $f") }
    }

    function ReadRows($ref){ try { @(Read-TiaRows -Ref $ref -BaseDir $base) } catch { @() } }

    foreach ($plc in @($spec.plcs)) {
        if (-not $plc) { continue }
        $rTag = Get-Rule 'tags'; $rUdt = Get-Rule 'udts'; $rDb = Get-Rule 'dbs'
        $rFb = Get-Rule 'fbs'; $rFc = Get-Rule 'fcs'; $rMod = Get-Rule 'modules'

        if ($rTag) { foreach ($t in @($plc.tags)) { if ($t) { foreach ($row in (ReadRows $t)) { Check $row.Name $rTag 'tag' } } } }
        if ($rUdt) {
            $seen = @{}
            foreach ($u in @($plc.udts)) { if ($u) { foreach ($row in (ReadRows $u)) { if ($row.UDT -and -not $seen.ContainsKey($row.UDT)) { $seen[$row.UDT]=$true; Check $row.UDT $rUdt 'udt' } } } }
        }
        if ($rDb -and $plc.dbs -and $plc.dbs.blocks) { foreach ($row in (ReadRows $plc.dbs.blocks)) { Check $row.DBName $rDb 'db' } }
        if ($rMod) { foreach ($m in @($plc.modules)) { if ($m) { foreach ($row in (ReadRows $m)) { Check $row.Name $rMod 'module' } } } }
        if ($rFb -or $rFc) {
            foreach ($l in @($plc.logic)) {
                if (-not $l) { continue }
                $lp = if ([System.IO.Path]::IsPathRooted($l)) { $l } else { Join-Path $base $l }
                if (-not (Test-Path $lp)) { continue }
                $txt = Get-Content $lp -Raw
                if ($rFb) { foreach ($mm in [regex]::Matches($txt,'(?im)^\s*FUNCTION_BLOCK\s+"?([A-Za-z_]\w*)"?')) { Check $mm.Groups[1].Value $rFb 'fb' } }
                if ($rFc) { foreach ($mm in [regex]::Matches($txt,'(?im)^\s*FUNCTION\s+"?([A-Za-z_]\w*)"?\s*:')) { Check $mm.Groups[1].Value $rFc 'fc' } }
            }
        }
    }

    $rHmi = Get-Rule 'hmiTags'
    if ($rHmi) {
        foreach ($hmi in @($spec.hmis)) { if ($hmi) { foreach ($t in @($hmi.tags)) { if ($t) { foreach ($row in (ReadRows $t)) { Check $row.Name $rHmi 'hmiTag' } } } } }
    }

    [pscustomobject]@{
        Ok         = ($violations.Count -eq 0)
        Violations = @($violations)
        Summary    = "Violations: $($violations.Count)"
    }
}
