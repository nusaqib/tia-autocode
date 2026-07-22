# TiaYaml.ps1 - a small, dependency-free YAML reader for tia-autocode manifests.
# Supports the manifest subset only: block mappings, block sequences (of scalars or
# mappings), inline [a, b] sequences, scalars (quoted/unquoted, bool, int, float),
# 2-space indentation, and # comments. NOT a general YAML implementation (no anchors,
# multi-line scalars, flow maps, etc.). Windows PowerShell 5.1, ASCII-only.

function ConvertFrom-TiaYamlScalar {
    param([string]$v)
    $v = $v.Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        return $v.Substring(1, $v.Length - 2)
    }
    switch -Regex ($v) {
        '^(true|True|TRUE)$'   { return $true }
        '^(false|False|FALSE)$'{ return $false }
        '^-?\d+$'              { return [int]$v }
        '^-?\d+\.\d+$'         { return [double]$v }
        '^(null|~|)$'          { return $null }
        default                { return $v }
    }
}

function ConvertFrom-TiaYamlInlineSeq {
    param([string]$v)
    $inner = $v.Trim()
    $inner = $inner.TrimStart('[').TrimEnd(']').Trim()
    if ($inner -eq '') { return @() }
    # naive split on commas (manifest inline seqs are simple scalar lists)
    return @($inner -split ',' | ForEach-Object { ConvertFrom-TiaYamlScalar $_.Trim() })
}

function ConvertFrom-TiaYamlComment {
    param([string]$line)
    $sb = New-Object System.Text.StringBuilder
    $inSingle = $false; $inDouble = $false
    for ($i = 0; $i -lt $line.Length; $i++) {
        $c = $line[$i]
        if ($c -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
        elseif ($c -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
        elseif ($c -eq '#' -and -not $inSingle -and -not $inDouble) {
            if ($i -eq 0 -or $line[$i-1] -eq ' ' -or $line[$i-1] -eq "`t") { break }
        }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

function ConvertFrom-TiaYamlMap {
    param($lines, [ref]$pos, [int]$indent)
    $map = [ordered]@{}
    while ($pos.Value -lt $lines.Count) {
        $ln = $lines[$pos.Value]
        if ($ln.Indent -ne $indent) { break }
        if ($ln.Text.StartsWith('- ') -or $ln.Text -eq '-') { break }
        $m = [regex]::Match($ln.Text, '^([^:]+):\s*(.*)$')
        if (-not $m.Success) { break }
        $key = $m.Groups[1].Value.Trim()
        $val = $m.Groups[2].Value.Trim()
        $pos.Value++
        if ($val -eq '') {
            if ($pos.Value -lt $lines.Count -and $lines[$pos.Value].Indent -gt $indent) {
                $map[$key] = ConvertFrom-TiaYamlNode $lines $pos $lines[$pos.Value].Indent
            } else { $map[$key] = $null }
        }
        elseif ($val.StartsWith('[')) { $map[$key] = ConvertFrom-TiaYamlInlineSeq $val }
        else { $map[$key] = ConvertFrom-TiaYamlScalar $val }
    }
    return $map
}

function ConvertFrom-TiaYamlNode {
    param($lines, [ref]$pos, [int]$indent)
    if ($pos.Value -ge $lines.Count) { return $null }
    $first = $lines[$pos.Value]
    if ($first.Indent -lt $indent) { return $null }
    $cur = $first.Indent

    if ($first.Text.StartsWith('- ') -or $first.Text -eq '-') {
        $seq = New-Object System.Collections.Generic.List[object]
        while ($pos.Value -lt $lines.Count) {
            $ln = $lines[$pos.Value]
            if ($ln.Indent -ne $cur -or -not ($ln.Text.StartsWith('- ') -or $ln.Text -eq '-')) { break }
            $content = if ($ln.Text -eq '-') { '' } else { $ln.Text.Substring(2) }
            if ($content -eq '') {
                $pos.Value++
                if ($pos.Value -lt $lines.Count -and $lines[$pos.Value].Indent -gt $cur) {
                    $seq.Add((ConvertFrom-TiaYamlNode $lines $pos $lines[$pos.Value].Indent))
                } else { $seq.Add($null) }
            }
            elseif ($content -match '^[^:\s][^:]*:(\s|$)') {
                # dash-inline mapping: rewrite this line to the content indent, parse a map there
                $contentIndent = $cur + 2
                $lines[$pos.Value] = [pscustomobject]@{ Indent = $contentIndent; Text = $content }
                $seq.Add((ConvertFrom-TiaYamlMap $lines $pos $contentIndent))
            }
            else {
                $seq.Add((ConvertFrom-TiaYamlScalar $content))
                $pos.Value++
            }
        }
        return ,$seq.ToArray()
    }
    return ConvertFrom-TiaYamlMap $lines $pos $cur
}

function ConvertFrom-TiaYaml {
    <#
    .SYNOPSIS
        Parses a tia-autocode manifest (YAML subset) into ordered hashtables/arrays.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($raw in ($Text -split "`r?`n")) {
        $stripped = ConvertFrom-TiaYamlComment $raw
        if ($stripped.Trim().Length -eq 0) { continue }
        $indent = $stripped.Length - $stripped.TrimStart(' ').Length
        $lines.Add([pscustomobject]@{ Indent = $indent; Text = $stripped.TrimStart(' ') })
    }
    if ($lines.Count -eq 0) { return [ordered]@{} }
    $pos = 0
    return ConvertFrom-TiaYamlNode $lines ([ref]$pos) $lines[0].Indent
}

function Read-TiaManifest {
    <#
    .SYNOPSIS
        Reads a project manifest from a .yaml/.yml or .json file into an object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Manifest not found: $Path" }
    $text = Get-Content $Path -Raw
    switch -Regex ([System.IO.Path]::GetExtension($Path)) {
        '\.ya?ml$' { return ConvertFrom-TiaYaml $text }
        '\.json$'  { return $text | ConvertFrom-Json }
        default    { throw "Unsupported manifest type '$Path' (use .yaml, .yml, or .json)." }
    }
}
