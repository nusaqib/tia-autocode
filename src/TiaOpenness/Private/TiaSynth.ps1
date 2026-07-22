# TiaSynth.ps1 - convert spreadsheet rows into SCL source (UDTs and DBs).
# Pure string functions (no TIA), so they are unit-testable offline.

# Canonical S7 primitive type set (lower-cased), shared by the synthesizer + validator.
$script:TiaPrimitiveTypes = @(
    'Bool','Byte','Word','DWord','LWord','SInt','USInt','Int','UInt','DInt','UDInt',
    'LInt','ULInt','Real','LReal','Time','LTime','S5Time','Date','Time_Of_Day','TOD',
    'Date_And_Time','DT','DTL','LDT','Char','WChar','String','WString'
) | ForEach-Object { $_.ToLowerInvariant() }

function Test-TiaPrimitive {
    param([string]$DataType)
    if (-not $DataType) { return $false }
    return ($script:TiaPrimitiveTypes -contains $DataType.Trim().Trim('"').ToLowerInvariant())
}

function Format-TiaMemberType {
    # Render a member's SCL type. UDT/type references are quoted; primitives are bare.
    # Optional array dims like "0..9" -> Array[0..9] of <base>.
    param([string]$DataType, [string]$Array)
    $dt = $DataType.Trim()
    $base = if (Test-TiaPrimitive $dt) { $dt } else { '"' + $dt.Trim('"') + '"' }
    if ($Array) { return "Array[$($Array.Trim())] of $base" }
    return $base
}

function ConvertTo-TiaUdtScl {
    <#
    .SYNOPSIS
        Builds SCL TYPE...END_TYPE text from UDT member rows (columns:
        UDT, Member, DataType, Array, StartValue, Comment). Multiple UDTs supported.
    #>
    param([Parameter(Mandatory)]$Rows)
    $out = New-Object System.Text.StringBuilder
    foreach ($grp in ($Rows | Group-Object UDT)) {
        if (-not $grp.Name) { continue }
        [void]$out.AppendLine("TYPE `"$($grp.Name)`"")
        [void]$out.AppendLine("VERSION : 0.1")
        [void]$out.AppendLine("STRUCT")
        foreach ($m in $grp.Group) {
            $type = Format-TiaMemberType $m.DataType $m.Array
            $line = "   $($m.Member) : $type"
            if ($m.StartValue) { $line += " := $($m.StartValue)" }
            $line += ";"
            if ($m.Comment) { $line += "   // $($m.Comment)" }
            [void]$out.AppendLine($line)
        }
        [void]$out.AppendLine("END_STRUCT;")
        [void]$out.AppendLine("END_TYPE")
        [void]$out.AppendLine("")
    }
    return $out.ToString()
}

function ConvertTo-TiaDbScl {
    <#
    .SYNOPSIS
        Builds SCL DATA_BLOCK text for one DB. $Block is a dbs.blocks row
        (DBName, Number, Kind, OfType, Optimized); $Members are dbs.members rows
        (Member, DataType, StartValue, Comment) - only used for Global DBs.
    #>
    param([Parameter(Mandatory)]$Block, $Members)
    $name = $Block.DBName
    $optFalse = ($Block.Optimized -and "$($Block.Optimized)" -match '^(?i:false|0|no)$')
    $attr = "{ S7_Optimized_Access := '$(if($optFalse){'FALSE'}else{'TRUE'})' }"

    $kind = "$($Block.Kind)".Trim()
    if ($kind -eq 'InstanceOfFB' -or $kind -eq 'TypedOfUDT') {
        $body = "`"$($Block.OfType.Trim().Trim('"'))`""
    } else {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("VAR")
        foreach ($m in @($Members)) {
            $type = Format-TiaMemberType $m.DataType $null
            $line = "   $($m.Member) : $type"
            if ($m.StartValue) { $line += " := $($m.StartValue)" }
            $line += ";"
            if ($m.Comment) { $line += "   // $($m.Comment)" }
            [void]$sb.AppendLine($line)
        }
        [void]$sb.Append("END_VAR")
        $body = $sb.ToString()
    }
    return "DATA_BLOCK `"$name`"`r`n$attr`r`n$body`r`nBEGIN`r`nEND_DATA_BLOCK`r`n"
}
