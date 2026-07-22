# Types.ps1 - PLC data types (UDTs) and data blocks (global/instance), via SCL sources.
# UDTs and DBs are most reliably authored as SCL text (TYPE...END_TYPE / DATA_BLOCK)
# and generated into the project, mirroring how Import-TiaScl handles code blocks.

function Get-TiaType {
    <#
    .SYNOPSIS
        Lists PLC user data types (UDTs), recursing into type groups.
    #>
    [CmdletBinding()]
    param([string]$Name, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    $out = New-Object System.Collections.Generic.List[object]
    function Walk($group, $path) {
        foreach ($t in $group.Types) {
            $out.Add([pscustomobject]@{ Name = $t.Name; Group = $path; Type = $t })
        }
        foreach ($g in $group.Groups) { Walk $g "$path/$($g.Name)" }
    }
    Walk $sw.TypeGroup ''
    if ($Name) { $out = $out | Where-Object { $_.Name -like $Name } }
    $out
}

function New-TiaType {
    <#
    .SYNOPSIS
        Creates a PLC data type (UDT) from SCL TYPE text.
    .EXAMPLE
        New-TiaType -Scl @'
        TYPE "MotorData"
        STRUCT
            Speed   : Real;
            Running : Bool;
            Faults  : Word;
        END_STRUCT;
        END_TYPE
        '@
    #>
    [CmdletBinding(DefaultParameterSetName='Text')]
    param(
        [Parameter(Mandatory, ParameterSetName='Text')][string]$Scl,
        [Parameter(Mandatory, ParameterSetName='File')][string]$Path,
        [string]$Name, [switch]$KeepSource, $Plc
    )
    # A UDT source is just an SCL external source containing TYPE...END_TYPE.
    $params = @{ Plc = $Plc; KeepSource = $KeepSource }
    if ($Name) { $params.Name = $Name }
    if ($PSCmdlet.ParameterSetName -eq 'Text') { $params.Scl = $Scl } else { $params.Path = $Path }
    Import-TiaScl @params
}

function New-TiaDataBlock {
    <#
    .SYNOPSIS
        Creates a global data block. Provide either an SCL body or an -OfType (to
        make an instance/typed DB "DB of <FB/UDT>").
    .PARAMETER Scl
        Full DATA_BLOCK ... END_DATA_BLOCK SCL text.
    .PARAMETER Name
        DB name (used when -OfType is given to synthesize the SCL).
    .PARAMETER OfType
        Name of an FB (instance DB) or UDT (typed DB) this DB is an instance of.
    .EXAMPLE
        New-TiaDataBlock -Scl @'
        DATA_BLOCK "Settings"
        { S7_Optimized_Access := 'TRUE' }
        VAR
            Setpoint : Real := 50.0;
            Enable   : Bool;
        END_VAR
        BEGIN
        END_DATA_BLOCK
        '@
    .EXAMPLE
        New-TiaDataBlock -Name Motor1_DB -OfType MotorStarter   # instance DB of an FB
    #>
    [CmdletBinding(DefaultParameterSetName='Text')]
    param(
        [Parameter(Mandatory, ParameterSetName='Text')][string]$Scl,
        [Parameter(Mandatory, ParameterSetName='OfType')][string]$Name,
        [Parameter(Mandatory, ParameterSetName='OfType')][string]$OfType,
        [switch]$KeepSource, $Plc
    )
    if ($PSCmdlet.ParameterSetName -eq 'OfType') {
        $Scl = "DATA_BLOCK `"$Name`"`r`n`"$OfType`"`r`nBEGIN`r`nEND_DATA_BLOCK`r`n"
        return Import-TiaScl -Plc $Plc -Scl $Scl -Name $Name -KeepSource:$KeepSource
    }
    Import-TiaScl -Plc $Plc -Scl $Scl -KeepSource:$KeepSource
}
