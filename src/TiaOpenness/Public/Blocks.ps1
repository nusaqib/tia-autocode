# Blocks.ps1 — PLC logic blocks (OB/FB/FC/DB): read, create from SCL, import XML, export, compile.

function Get-TiaBlock {
    <#
    .SYNOPSIS
        Lists PLC blocks (OB/FB/FC/DB), recursing into block groups.
    .EXAMPLE
        Get-TiaBlock | Format-Table Name, Type, Number, Language
    #>
    [CmdletBinding()]
    param([string]$Name, [ValidateSet('OB','FB','FC','GlobalDB','InstanceDB','Any')][string]$Type = 'Any', $Plc)
    $sw = Resolve-PlcSoftware $Plc

    $out = New-Object System.Collections.Generic.List[object]
    function Walk($group, $path) {
        foreach ($b in $group.Blocks) {
            $kind = $b.GetType().Name   # OB / FB / FC / GlobalDB / InstanceDB
            $out.Add([pscustomobject]@{
                Name     = $b.Name
                Type     = $kind
                Number   = Get-Safe { $b.Number }
                Language = Get-Safe { $b.ProgrammingLanguage }
                Group    = $path
                Modified = Get-Safe { $b.ModifiedDate }
                Block    = $b
            })
        }
        foreach ($g in $group.Groups) { Walk $g "$path/$($g.Name)" }
    }
    Walk $sw.BlockGroup ''
    if ($Type -ne 'Any') { $out = $out | Where-Object { $_.Type -eq $Type } }
    if ($Name) { $out = $out | Where-Object { $_.Name -like $Name } }
    $out
}

function Import-TiaScl {
    <#
    .SYNOPSIS
        Creates/updates one or more blocks from SCL source text or a .scl file.
    .DESCRIPTION
        The reliable, text-first way to author functions and routines: the SCL is
        registered as an external source, then GenerateBlocksFromSource() compiles
        it into real FC/FB/OB blocks in the block folder. The external source is
        removed afterwards unless -KeepSource is given.
    .PARAMETER Scl
        SCL source text (must contain a FUNCTION / FUNCTION_BLOCK / ORGANIZATION_BLOCK
        ... END_... construct).
    .PARAMETER Path
        Path to an existing .scl file (alternative to -Scl).
    .PARAMETER Name
        Logical name for the external source object (defaults to the block name / file).
    .EXAMPLE
        Import-TiaScl -Scl @'
        FUNCTION "Scale" : Real
        VAR_INPUT raw : Int; END_VAR
        BEGIN
            #Scale := INT_TO_REAL(#raw) * 0.1;
        END_FUNCTION
        '@
    #>
    [CmdletBinding(DefaultParameterSetName='Text')]
    param(
        [Parameter(Mandatory, ParameterSetName='Text')][string]$Scl,
        [Parameter(Mandatory, ParameterSetName='File')][string]$Path,
        [string]$Name,
        [switch]$KeepSource,
        $Plc
    )
    $sw = Resolve-PlcSoftware $Plc

    if ($PSCmdlet.ParameterSetName -eq 'Text') {
        if (-not $Name) {
            $m = [regex]::Match($Scl, '(?im)^\s*(?:FUNCTION_BLOCK|FUNCTION|ORGANIZATION_BLOCK|DATA_BLOCK)\s+"?([A-Za-z_][\w]*)"?')
            $Name = if ($m.Success) { $m.Groups[1].Value } else { "GeneratedSource" }
        }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("$Name.scl")
        Set-Content -Path $tmp -Value $Scl -Encoding UTF8
        $sourcePath = $tmp
    } else {
        if (-not (Test-Path $Path)) { throw "SCL file not found: $Path" }
        $sourcePath = (Resolve-Path $Path).Path
        if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath) }
    }

    $fi = New-Object System.IO.FileInfo($sourcePath)
    # Remove a stale external source of the same name to allow re-import.
    $existing = $sw.ExternalSourceGroup.ExternalSources | Where-Object { $_.Name -eq $Name }
    if ($existing) { $existing.Delete() }

    Write-Verbose "Registering external source '$Name' from $sourcePath ..."
    $src = $sw.ExternalSourceGroup.ExternalSources.CreateFromFile($Name, $fi)
    Write-Verbose "Generating blocks from source ..."
    $genResult = $src.GenerateBlocksFromSource()

    if (-not $KeepSource) { $src.Delete() }
    if ($PSCmdlet.ParameterSetName -eq 'Text') { Remove-Item $tmp -ErrorAction SilentlyContinue }

    [pscustomobject]@{ SourceName = $Name; GenerationState = $genResult }
}

function Import-TiaBlockXml {
    <#
    .SYNOPSIS
        Imports a block from a SimaticML (Openness XML) file.
    .DESCRIPTION
        The full-fidelity path for LAD/FBD/SCL/STL blocks with networks, interfaces,
        and comments. Use Export-TiaBlock to see the exact schema for your version.
    .PARAMETER Path
        Path to the .xml SimaticML document.
    .PARAMETER Overwrite
        Overwrite an existing block with the same name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    if (-not (Test-Path $Path)) { throw "XML file not found: $Path" }
    $fi = New-Object System.IO.FileInfo((Resolve-Path $Path).Path)
    $opt = if ($Overwrite) {
        [Siemens.Engineering.ImportOptions]::Override
    } else {
        [Siemens.Engineering.ImportOptions]::None
    }
    $sw.BlockGroup.Blocks.Import($fi, $opt)
}

function Export-TiaBlock {
    <#
    .SYNOPSIS
        Exports a block to SimaticML XML (great for learning the schema / round-tripping).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Plc)
    $b = (Get-TiaBlock -Plc $Plc -Name $Name | Select-Object -First 1).Block
    if (-not $b) { throw "Block '$Name' not found." }
    $fi = New-Object System.IO.FileInfo($Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ExportOptions]::WithDefaults } else { [Siemens.Engineering.ExportOptions]::None }
    $b.Export($fi, $opt)
    $Path
}

function Invoke-TiaCompile {
    <#
    .SYNOPSIS
        Compiles a single block or the whole PLC software and returns the result summary.
    .PARAMETER BlockName
        Compile just this block; omit to compile the entire PLC.
    #>
    [CmdletBinding()]
    param([string]$BlockName, $Plc)
    $sw = Resolve-PlcSoftware $Plc

    $target = if ($BlockName) {
        $b = (Get-TiaBlock -Plc $sw -Name $BlockName | Select-Object -First 1).Block
        if (-not $b) { throw "Block '$BlockName' not found." }
        $b
    } else { $sw }

    $icomp = [Siemens.Engineering.Compiler.ICompilable]
    $mi = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($icomp)
    $compiler = $mi.Invoke($target, $null)
    $result = $compiler.Compile()

    [pscustomobject]@{
        State    = $result.State
        Warnings = $result.WarningCount
        Errors   = $result.ErrorCount
        Messages = @($result.Messages | ForEach-Object { "$($_.State): $($_.Description)" })
        Result   = $result
    }
}
