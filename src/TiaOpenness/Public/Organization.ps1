# Organization.ps1 - block/tag folder groups and block lifecycle helpers.

function New-TiaBlockGroup {
    <#
    .SYNOPSIS
        Creates (or returns) a nested block group (folder) by path, e.g. 'Motion/Axes'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    $group = $sw.BlockGroup
    foreach ($seg in ($Path -split '[\\/]+' | Where-Object { $_ })) {
        $child = $group.Groups | Where-Object { $_.Name -eq $seg } | Select-Object -First 1
        if (-not $child) { $child = $group.Groups.Create($seg) }
        $group = $child
    }
    $group
}

function Remove-TiaBlock {
    <#
    .SYNOPSIS
        Deletes a block by name. Use -WhatIf to preview.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$Name, $Plc)
    $b = (Get-TiaBlock -Plc $Plc -Name $Name | Select-Object -First 1).Block
    if (-not $b) { throw "Block '$Name' not found." }
    if ($PSCmdlet.ShouldProcess($Name, 'Delete PLC block')) { $b.Delete() }
}

function New-TiaOb {
    <#
    .SYNOPSIS
        Creates an Organization Block (OB) from SCL. Give an event class where needed.
    .DESCRIPTION
        Cyclic program is OB1 (Main). For startup/cyclic-interrupt/etc. write the
        ORGANIZATION_BLOCK with the appropriate name; TIA maps standard OB names.
    .EXAMPLE
        New-TiaOb -Scl @'
        ORGANIZATION_BLOCK "Main"
        BEGIN
            "MotorStarter_DB"(Start := "Start_PB", Stop := "Stop_PB");
        END_ORGANIZATION_BLOCK
        '@
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Scl, [switch]$KeepSource, $Plc)
    Import-TiaScl -Plc $Plc -Scl $Scl -KeepSource:$KeepSource
}

function Get-TiaBlockGroup {
    <#
    .SYNOPSIS
        Lists block groups (folders) in the PLC block tree.
    #>
    [CmdletBinding()]
    param($Plc)
    $sw = Resolve-PlcSoftware $Plc
    $out = New-Object System.Collections.Generic.List[object]
    function Walk($group, $path) {
        foreach ($g in $group.Groups) {
            $p = "$path/$($g.Name)"
            $out.Add([pscustomobject]@{ Path = $p.TrimStart('/'); BlockCount = $g.Blocks.Count; Group = $g })
            Walk $g $p
        }
    }
    Walk $sw.BlockGroup ''
    $out
}
