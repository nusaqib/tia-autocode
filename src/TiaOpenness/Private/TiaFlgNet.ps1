# F-LAD network (FlgNet) emitters for the sheet-driven builder.
#
# Every construct here is the canonical form proven live in the PPS_SR_LAB spike. FlgNet is
# strictly ordered and strictly connected: a Part with an unwired pin, or elements in the
# wrong order, is rejected on import with a misleading message. Do not reorder or drop
# wires without re-testing against a real import.
#
# Rung shape (LAD):  Powerrail --> Contact.in ; Contact.out --> Coil.in
#                    operand wires attach an Access to Contact.operand / Coil.operand

function New-TiaFlgBuilder {
    <#
    .SYNOPSIS
        Accumulator for one network: Accesses, Parts and Wires with unique UIds.
    #>
    # A LAD network may contain exactly ONE power rail, however many rungs it has, so the
    # pins it feeds are collected here and emitted as a single fan-out wire by
    # New-TiaFlgCompileUnit. One Powerrail element per rung is rejected on import with
    # "In LAD, networks can only contain one power rail."
    [pscustomobject]@{
        Uid           = 20       # 21+ matches the exported canonical numbering
        Accesses      = New-Object System.Collections.Generic.List[string]
        Parts         = New-Object System.Collections.Generic.List[string]
        Wires         = New-Object System.Collections.Generic.List[string]
        PowerrailPins = New-Object System.Collections.Generic.List[string]
    }
}

function Add-TiaFlgAccess {
    <#
    .SYNOPSIS
        A symbolic operand. -Path is a dotted symbol: "MyTag" or "DB_BTA.SE0101.EMO.ChA".
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][string]$Path)
    $Builder.Uid++
    $uid = $Builder.Uid
    $comp = ($Path -split '\.' | ForEach-Object { "        <Component Name=""$(ConvertTo-TiaXmlText $_)"" />" }) -join "`r`n"
    $Builder.Accesses.Add(@"
    <Access Scope="GlobalVariable" UId="$uid">
      <Symbol>
$comp
      </Symbol>
    </Access>
"@)
    $uid
}

function Add-TiaFlgPart {
    <#
    .SYNOPSIS
        A LAD element. -Negated emits <Negated Name="operand" /> (an NC contact).
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][string]$Name,
          [switch]$Negated, [string]$Version)
    $Builder.Uid++
    $uid = $Builder.Uid
    $ver = if ($Version) { " Version=""$Version""" } else { '' }
    if ($Negated) {
        $Builder.Parts.Add("    <Part Name=""$Name"" UId=""$uid""$ver><Negated Name=""operand"" /></Part>")
    } else {
        $Builder.Parts.Add("    <Part Name=""$Name"" UId=""$uid""$ver />")
    }
    $uid
}

function Add-TiaFlgWire {
    <#
    .SYNOPSIS
        Wire a source to one or more named pins. -FromPowerrail starts the rung.
    .PARAMETER To
        Pairs "<uid>:<pinName>".
    #>
    param([Parameter(Mandatory)]$Builder, [int]$FromAccess, [string]$FromPin,
          [switch]$FromPowerrail, [Parameter(Mandatory)][string[]]$To)
    $Builder.Uid++
    $uid = $Builder.Uid
    $src = if ($FromPowerrail) { '      <Powerrail />' }
           elseif ($FromAccess) { "      <IdentCon UId=""$FromAccess"" />" }
           elseif ($FromPin)    { $p = $FromPin -split ':', 2; "      <NameCon UId=""$($p[0])"" Name=""$($p[1])"" />" }
           else { throw 'Add-TiaFlgWire needs a source' }
    $dst = ($To | ForEach-Object { $p = $_ -split ':', 2; "      <NameCon UId=""$($p[0])"" Name=""$($p[1])"" />" }) -join "`r`n"
    $Builder.Wires.Add(@"
    <Wire UId="$uid">
$src
$dst
    </Wire>
"@)
    $uid
}

function Add-TiaFlgOpenWire {
    <#
    .SYNOPSIS
        Leave a pin unconnected. FlgNet requires EVERY pin of an instruction to be wired -
        an unused one gets an OpenCon, not omission.
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][int]$PartUid,
          [Parameter(Mandatory)][string]$Pin)
    $Builder.Uid++
    $openUid = $Builder.Uid
    $Builder.Uid++
    $wireUid = $Builder.Uid
    $Builder.Wires.Add(@"
    <Wire UId="$wireUid">
      <OpenCon UId="$openUid" />
      <NameCon UId="$PartUid" Name="$(ConvertTo-TiaXmlText $Pin)" />
    </Wire>
"@)
    $wireUid
}

function Add-TiaFlgRung {
    <#
    .SYNOPSIS
        One contact driving one coil: --| |-- ( ) - the IOMap workhorse.
    .PARAMETER Negated
        Emit an NC contact (Polarity=NO in the sheet: 1 means demand, so it is inverted).
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][string]$From,
          [Parameter(Mandatory)][string]$To, [switch]$Negated)
    $src = Add-TiaFlgAccess -Builder $Builder -Path $From
    $dst = Add-TiaFlgAccess -Builder $Builder -Path $To
    $contact = Add-TiaFlgPart -Builder $Builder -Name 'Contact' -Negated:$Negated
    $coil    = Add-TiaFlgPart -Builder $Builder -Name 'Coil'
    $Builder.PowerrailPins.Add("${contact}:in")
    Add-TiaFlgWire -Builder $Builder -FromAccess $src -To @("${contact}:operand") | Out-Null
    Add-TiaFlgWire -Builder $Builder -FromPin "${contact}:out" -To @("${coil}:in") | Out-Null
    Add-TiaFlgWire -Builder $Builder -FromAccess $dst -To @("${coil}:operand") | Out-Null
    $coil
}

function New-TiaFlgCompileUnit {
    <#
    .SYNOPSIS
        Wrap a builder's contents as one SW.Blocks.CompileUnit (one network).
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][int]$Id, [string]$Title = '')
    $parts = ($Builder.Accesses + $Builder.Parts) -join "`r`n"
    $all = New-Object System.Collections.Generic.List[string]
    if ($Builder.PowerrailPins.Count) {
        $Builder.Uid++
        $pins = ($Builder.PowerrailPins | ForEach-Object {
                    $p = $_ -split ':', 2; "      <NameCon UId=""$($p[0])"" Name=""$($p[1])"" />" }) -join "`r`n"
        $all.Add("    <Wire UId=""$($Builder.Uid)"">`r`n      <Powerrail />`r`n$pins`r`n    </Wire>")
    }
    foreach ($w in $Builder.Wires) { $all.Add($w) }
    $wires = $all -join "`r`n"
    @"
      <SW.Blocks.CompileUnit ID="$Id" CompositionName="CompileUnits">
        <AttributeList>
          <NetworkSource><FlgNet xmlns="http://www.siemens.com/automation/Openness/SW/NetworkSource/FlgNet/v5">
  <Parts>
$parts
  </Parts>
  <Wires>
$wires
  </Wires>
</FlgNet></NetworkSource>
          <ProgrammingLanguage>F_LAD</ProgrammingLanguage>
        </AttributeList>
        <ObjectList>
$(New-TiaMlMultilingualText -Id ($Id + 1) -Composition 'Comment')
$(New-TiaMlMultilingualText -Id ($Id + 3) -Composition 'Title' -Text $Title)
        </ObjectList>
      </SW.Blocks.CompileUnit>
"@
}

function New-TiaFailsafeFbXml {
    <#
    .SYNOPSIS
        Canonical fail-safe FB (SW.Blocks.FB, ProgrammingLanguage F_LAD) with networks.
    .PARAMETER Statics
        Multi-instance statics: rows with Name and Datatype (an instruction like
        "ESTOP1" or a nested FB). These are what make certified instances possible
        without separate instance DBs.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string[]]$CompileUnits,
        $Statics,
        [string]$Version = 'V19'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<Document>')
    [void]$sb.AppendLine("  <Engineering version=""$Version"" />")
    [void]$sb.AppendLine('  <SW.Blocks.FB ID="0">')
    [void]$sb.AppendLine('    <AttributeList>')
    [void]$sb.AppendLine('      <AutoNumber>false</AutoNumber>')
    [void]$sb.AppendLine('      <HeaderAuthor />')
    [void]$sb.AppendLine('      <HeaderFamily />')
    [void]$sb.AppendLine('      <HeaderName />')
    [void]$sb.AppendLine('      <HeaderVersion>0.1</HeaderVersion>')
    [void]$sb.AppendLine('      <Interface><Sections xmlns="http://www.siemens.com/automation/Openness/SW/Interface/v5">')
    [void]$sb.AppendLine('  <Section Name="Input" />')
    [void]$sb.AppendLine('  <Section Name="Output" />')
    [void]$sb.AppendLine('  <Section Name="InOut" />')
    if ($Statics -and @($Statics).Count) {
        [void]$sb.AppendLine('  <Section Name="Static">')
        foreach ($s in $Statics) {
            $dt = Format-TiaMlDatatype $s.Datatype
            [void]$sb.AppendLine("    <Member Name=""$(ConvertTo-TiaXmlText $s.Name)"" Datatype=""$dt"" Remanence=""NonRetain"" Accessibility=""Public"" />")
        }
        [void]$sb.AppendLine('  </Section>')
    } else {
        [void]$sb.AppendLine('  <Section Name="Static" />')
    }
    [void]$sb.AppendLine('  <Section Name="Temp" />')
    [void]$sb.AppendLine('  <Section Name="Constant" />')
    [void]$sb.AppendLine('</Sections></Interface>')
    [void]$sb.AppendLine('      <IsIECCheckEnabled>false</IsIECCheckEnabled>')
    [void]$sb.AppendLine('      <MemoryLayout>Optimized</MemoryLayout>')
    [void]$sb.AppendLine("      <Name>$(ConvertTo-TiaXmlText $Name)</Name>")
    [void]$sb.AppendLine('      <Namespace />')
    [void]$sb.AppendLine("      <Number>$Number</Number>")
    [void]$sb.AppendLine('      <ProgrammingLanguage>F_LAD</ProgrammingLanguage>')
    [void]$sb.AppendLine('      <UDABlockProperties />')
    [void]$sb.AppendLine('      <UDAEnableTagReadback>false</UDAEnableTagReadback>')
    [void]$sb.AppendLine('    </AttributeList>')
    [void]$sb.AppendLine('    <ObjectList>')
    [void]$sb.Append((New-TiaMlMultilingualText -Id 1 -Composition 'Comment'))
    foreach ($cu in $CompileUnits) { [void]$sb.AppendLine($cu) }
    [void]$sb.AppendLine('    </ObjectList>')
    [void]$sb.AppendLine('  </SW.Blocks.FB>')
    [void]$sb.AppendLine('</Document>')
    $sb.ToString()
}
