# Tags.ps1 — PLC tag tables and tags (read + create).

function Get-TiaTagTable {
    <#
    .SYNOPSIS
        Lists PLC tag tables (recursing into tag-table groups).
    #>
    [CmdletBinding()]
    param([string]$Name, $Plc)
    $sw = Resolve-PlcSoftware $Plc

    $out = New-Object System.Collections.Generic.List[object]
    function Walk($group, $path) {
        foreach ($t in $group.TagTables) {
            $out.Add([pscustomobject]@{
                Name     = $t.Name
                Group    = $path
                TagCount = $t.Tags.Count
                TagTable = $t
            })
        }
        foreach ($g in $group.Groups) { Walk $g "$path/$($g.Name)" }
    }
    Walk $sw.TagTableGroup ''
    if ($Name) { $out = $out | Where-Object { $_.Name -eq $Name } }
    $out
}

function Get-TiaTag {
    <#
    .SYNOPSIS
        Lists PLC tags across all tag tables (or one table).
    .EXAMPLE
        Get-TiaTag | Where DataType -eq 'Bool'
    #>
    [CmdletBinding()]
    param([string]$TagTable, [string]$Name, $Plc)
    $tables = Get-TiaTagTable -Plc $Plc
    if ($TagTable) { $tables = $tables | Where-Object { $_.Name -eq $TagTable } }

    foreach ($tt in $tables) {
        foreach ($tag in $tt.TagTable.Tags) {
            $obj = [pscustomobject]@{
                Name     = $tag.Name
                DataType = $tag.DataTypeName
                Address  = $tag.LogicalAddress
                Table    = $tt.Name
                Comment  = Get-Safe { $tag.Comment.Items[0].Text }
                Tag      = $tag
            }
            if (-not $Name -or $obj.Name -like $Name) { $obj }
        }
    }
}

function New-TiaTagTable {
    <#
    .SYNOPSIS
        Creates a PLC tag table (idempotent: returns the existing one if present).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    $existing = Get-TiaTagTable -Plc $sw -Name $Name | Select-Object -First 1
    if ($existing) { Write-Verbose "Tag table '$Name' already exists."; return $existing.TagTable }
    $sw.TagTableGroup.TagTables.Create($Name)
}

function New-TiaTag {
    <#
    .SYNOPSIS
        Creates a PLC tag in a tag table.
    .PARAMETER TagTable
        Target tag table name (created if missing).
    .PARAMETER DataType
        S7 data type, e.g. Bool, Int, Real, Word, "DInt".
    .PARAMETER Address
        Absolute address, e.g. %I0.0, %Q0.1, %M10.0, %MW20, %DB1.DBX0.0.
    .EXAMPLE
        New-TiaTag -TagTable IO -Name Start_PB -DataType Bool -Address '%I0.0'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DataType,
        [Parameter(Mandatory)][string]$Address,
        [string]$TagTable = 'Default tag table',
        [string]$Comment,
        $Plc
    )
    $sw = Resolve-PlcSoftware $Plc
    $tt = New-TiaTagTable -Plc $sw -Name $TagTable
    $tag = $tt.Tags.Create($Name, $DataType, $Address)
    if ($Comment) { try { $tag.Comment.Items[0].Text = $Comment } catch { } }
    [pscustomobject]@{
        Name = $tag.Name; DataType = $tag.DataTypeName; Address = $tag.LogicalAddress; Table = $tt.Name; Tag = $tag
    }
}
