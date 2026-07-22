# Templates.ps1 - reusable UDT/SCL template library (Phase 4).
# A template is an SCL/UDT file with {{Token}} placeholders and a small metadata header
# (// @template, // @kind, // @description, // @param name[=default] desc). Expand it with
# a parameter set to get ready-to-import SCL. Built-in templates live in the module's
# templates/ folder; point -TemplateDir elsewhere for a project's own library.

# Captured at dot-source time (top-level $PSScriptRoot = the Public folder, reliably).
$script:TiaTemplateDefaultDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates'

function Get-TiaTemplateDir {
    param([string]$TemplateDir)
    if ($TemplateDir) { return $TemplateDir }
    $script:TiaTemplateDefaultDir
}

function Read-TiaTemplateMeta {
    # Parse the // @meta header of a template file into { Name, Kind, Description, Params, Body }.
    param([string]$Path)
    $lines = Get-Content $Path
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '\.(fb|fc|ob|udt|db)\.scl$','' -replace '\.scl$',''
    $kind = ''; $desc = ''
    $params = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^//\s*@template\s+(.+)$') { $name = $Matches[1].Trim() }
        elseif ($t -match '^//\s*@kind\s+(.+)$') { $kind = $Matches[1].Trim() }
        elseif ($t -match '^//\s*@description\s+(.+)$') { $desc = $Matches[1].Trim() }
        elseif ($t -match '^//\s*@param\s+(\S+)\s*(.*)$') {
            $token = $Matches[1]; $pdesc = $Matches[2].Trim()
            $pname = $token; $pdef = $null
            if ($token -match '^([^=]+)=(.*)$') { $pname = $Matches[1]; $pdef = $Matches[2] }
            $params.Add([pscustomobject]@{ Name = $pname; Default = $pdef; Description = $pdesc })
        }
    }
    # Use .ToArray(): @($list) on a List[object] of PSCustomObjects trips a PS 5.1
    # "Argument types do not match" quirk. ToArray() is safe.
    $paramArr = $params.ToArray()
    [pscustomobject]@{ Name = $name; Kind = $kind; Description = $desc; Params = $paramArr; File = $Path }
}

function Get-TiaTemplate {
    <#
    .SYNOPSIS
        Lists reusable SCL/UDT templates (name, kind, params) from the template library.
    .PARAMETER Name
        Return just this template (by @template name or file base name).
    .PARAMETER TemplateDir
        Template folder; defaults to the module's built-in templates/.
    .EXAMPLE
        Get-TiaTemplate | Format-Table Name, Kind, Description
    #>
    [CmdletBinding()]
    param([string]$Name, [string]$TemplateDir)
    $dir = Get-TiaTemplateDir $TemplateDir
    if (-not (Test-Path $dir)) { throw "Template directory not found: $dir" }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem $dir -Filter '*.tmpl' -File) { $out.Add((Read-TiaTemplateMeta $f.FullName)) }
    if ($Name) { $out = $out | Where-Object { $_.Name -eq $Name } }
    $out
}

function Expand-TiaTemplate {
    <#
    .SYNOPSIS
        Expands a template with a parameter set into ready-to-import SCL text.
    .DESCRIPTION
        Replaces every {{Param}} token with the supplied value (or the template's default).
        Throws if a parameter without a default is not supplied, or if any {{...}} token is
        left unreplaced. The // @meta header lines are stripped from the output.
    .PARAMETER Name
        Template name (@template or file base name).
    .PARAMETER Parameters
        Hashtable/dictionary of token -> value.
    .PARAMETER OutFile
        Optional path to write the expanded SCL to (also returned as a string).
    .PARAMETER TemplateDir
        Template folder; defaults to the module's built-in templates/.
    .EXAMPLE
        Expand-TiaTemplate -Name MotorStarter -Parameters @{ Name='FB_Conveyor' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Parameters,
        [string]$OutFile,
        [string]$TemplateDir
    )
    $meta = Get-TiaTemplate -Name $Name -TemplateDir $TemplateDir | Select-Object -First 1
    if (-not $meta) { throw "Template '$Name' not found in $(Get-TiaTemplateDir $TemplateDir)." }

    function Val($params, $key) {
        if ($null -eq $params) { return $null }
        if ($params -is [System.Collections.IDictionary]) { if ($params.Contains($key)) { return $params[$key] } return $null }
        $p = $params.PSObject.Properties[$key]; if ($p) { return $p.Value } return $null
    }

    # Resolve each declared param: supplied value wins, else default; error if neither.
    $values = @{}
    foreach ($p in $meta.Params) {
        $v = Val $Parameters $p.Name
        if ($null -eq $v -or "$v" -eq '') {
            if ($null -ne $p.Default -and "$($p.Default)" -ne '') { $v = $p.Default }
            else { throw "Template '$Name' requires parameter '$($p.Name)' ($($p.Description))." }
        }
        $values[$p.Name] = $v
    }

    # Body = file minus the @meta header lines.
    $body = (Get-Content $meta.File | Where-Object { $_.Trim() -notmatch '^//\s*@(template|kind|description|param)\b' }) -join "`r`n"
    foreach ($k in $values.Keys) { $body = $body -replace ('\{\{' + [regex]::Escape($k) + '\}\}'), [string]$values[$k] }

    $leftover = [regex]::Matches($body, '\{\{[^}]+\}\}')
    if ($leftover.Count) { throw "Template '$Name' has unresolved tokens: $(($leftover | ForEach-Object { $_.Value }) -join ', ')" }

    if ($OutFile) { Set-Content -Path $OutFile -Value $body -Encoding ASCII; return $OutFile }
    $body
}
