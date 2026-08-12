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

# Pin sets of the certified Siemens F-application blocks, in the order the exported
# canonical XML wires them. EVERY pin must appear in the network: an input left out is an
# import error, so unused ones get an OpenCon.
# Value pins (DISCTIME/TIME_DEL) are deliberately left open - Time literals like T#0s are
# REJECTED by the FlgNet importer, so those are set in TIA.
$script:TiaCertifiedPins = @{
    'EV1oo2DI' = [ordered]@{
        In  = @('IN1','IN2','DISCTIME','ACK_NEC','ACK')
        Out = @('Q','ACK_REQ','DISC_FLT','DIAG')
        Template = [ordered]@{ 'f_user_card' = @('Cardinality','1'); 'f_image_card' = @('Cardinality','0')
                               'f_imageclassic_card' = @('Cardinality','0'); 'f_imageplus_card' = @('Cardinality','0')
                               'codedbool_type' = @('Type','DInt') }
        Version = '1.3'
    }
    'ESTOP1' = [ordered]@{
        In  = @('E_STOP','ACK_NEC','ACK','TIME_DEL')
        Out = @('Q','Q_DELAY','ACK_REQ','DIAG')
        Template = [ordered]@{ 'f_user_card' = @('Cardinality','1'); 'f_image_card' = @('Cardinality','0') }
        Version = '1.6'
    }
    # SFDOOR also takes QBAD_IN1/QBAD_IN2 (the passivation status of each input channel).
    # Omitting them fails the import with "The connection with the name 'QBAD_IN1' is not
    # connected to the object with the UID ...".
    'SFDOOR' = [ordered]@{
        In  = @('QBAD_IN1','QBAD_IN2','IN1','IN2','OPEN_NEC','ACK_NEC','ACK')
        Out = @('Q','ACK_REQ','DIAG')
        Template = [ordered]@{ 'f_user_card' = @('Cardinality','1'); 'f_image_card' = @('Cardinality','0') }
        Version = '1.3'
    }
}

function Add-TiaFlgCertifiedCall {
    <#
    .SYNOPSIS
        A certified F-application block call (ESTOP1 / SFDOOR / EV1oo2DI).
    .DESCRIPTION
        <Instance Scope="LocalVariable"> must be the FIRST child of the Part, before any
        TemplateValue - not because instance binding is optional, but because SimaticML is
        order-sensitive and reports the violation as "invalid child element".
        Multi-instance statics mean no separate F-instance DBs are needed.
    .PARAMETER Inputs
        Pin -> operand symbol path. Pins omitted here are wired OpenCon.
    .PARAMETER Outputs
        Pin -> operand symbol path. Same rule.
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][string]$Instruction,
          [Parameter(Mandatory)][string]$InstanceName, [hashtable]$Inputs = @{},
          [hashtable]$Outputs = @{}, [string]$Version)

    $spec = $script:TiaCertifiedPins[$Instruction]
    if (-not $spec) { throw "Unknown certified instruction '$Instruction'." }
    if (-not $Version) { $Version = $spec.Version }

    $Builder.Uid++
    $partUid = $Builder.Uid
    $Builder.Uid++
    $instUid = $Builder.Uid
    $tmpl = ($spec.Template.Keys | ForEach-Object {
        $t = $spec.Template[$_]
        "      <TemplateValue Name=""$_"" Type=""$($t[0])"">$($t[1])</TemplateValue>"
    }) -join "`r`n"
    $Builder.Parts.Add(@"
    <Part Name="$Instruction" Version="$Version" UId="$partUid">
      <Instance Scope="LocalVariable" UId="$instUid">
        <Component Name="$(ConvertTo-TiaXmlText $InstanceName)" />
      </Instance>
$tmpl
    </Part>
"@)

    $Builder.PowerrailPins.Add("${partUid}:en")
    foreach ($pin in $spec.In) {
        if ($Inputs.ContainsKey($pin) -and $Inputs[$pin]) {
            $a = Add-TiaFlgAccess -Builder $Builder -Path $Inputs[$pin]
            Add-TiaFlgWire -Builder $Builder -FromAccess $a -To @("${partUid}:$pin") | Out-Null
        } else {
            Add-TiaFlgOpenWire -Builder $Builder -PartUid $partUid -Pin $pin | Out-Null
        }
    }
    foreach ($pin in $spec.Out) {
        if ($Outputs.ContainsKey($pin) -and $Outputs[$pin]) {
            $a = Add-TiaFlgAccess -Builder $Builder -Path $Outputs[$pin]
            $Builder.Uid++
            $Builder.Wires.Add(@"
    <Wire UId="$($Builder.Uid)">
      <NameCon UId="$partUid" Name="$pin" />
      <IdentCon UId="$a" />
    </Wire>
"@)
        } else {
            $Builder.Uid++
            $openUid = $Builder.Uid
            $Builder.Uid++
            $Builder.Wires.Add(@"
    <Wire UId="$($Builder.Uid)">
      <NameCon UId="$partUid" Name="$pin" />
      <OpenCon UId="$openUid" />
    </Wire>
"@)
        }
    }
    $partUid
}

function Add-TiaFlgSeriesRung {
    <#
    .SYNOPSIS
        Contacts in SERIES driving one or more coils - the AND that forms an interlock.
    .DESCRIPTION
        Only the FIRST contact touches the power rail; each subsequent contact's "in" is
        wired from the previous contact's "out". That series chain IS the AND: one open
        contact drops the coil.
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][string[]]$From,
          [Parameter(Mandatory)][string[]]$To)
    if (-not $From.Count) { throw 'Add-TiaFlgSeriesRung needs at least one contact' }
    $prev = $null
    foreach ($f in $From) {
        $a = Add-TiaFlgAccess -Builder $Builder -Path $f
        $c = Add-TiaFlgPart -Builder $Builder -Name 'Contact'
        if ($null -eq $prev) { $Builder.PowerrailPins.Add("${c}:in") }
        else { Add-TiaFlgWire -Builder $Builder -FromPin "${prev}:out" -To @("${c}:in") | Out-Null }
        Add-TiaFlgWire -Builder $Builder -FromAccess $a -To @("${c}:operand") | Out-Null
        $prev = $c
    }
    $coilPins = @()
    foreach ($t in $To) {
        $a = Add-TiaFlgAccess -Builder $Builder -Path $t
        $coil = Add-TiaFlgPart -Builder $Builder -Name 'Coil'
        $coilPins += "${coil}:in"
        Add-TiaFlgWire -Builder $Builder -FromAccess $a -To @("${coil}:operand") | Out-Null
    }
    Add-TiaFlgWire -Builder $Builder -FromPin "${prev}:out" -To $coilPins | Out-Null
    $prev
}

function Add-TiaFlgCall {
    <#
    .SYNOPSIS
        Call an FB as a multi-instance (the safety runtime calling each zone block).
    #>
    param([Parameter(Mandatory)]$Builder, [Parameter(Mandatory)][string]$Block,
          [Parameter(Mandatory)][string]$InstanceName)
    $Builder.Uid++
    $callUid = $Builder.Uid
    $Builder.Uid++
    $instUid = $Builder.Uid
    $Builder.Parts.Add(@"
    <Call UId="$callUid">
      <CallInfo Name="$(ConvertTo-TiaXmlText $Block)" BlockType="FB">
        <Instance Scope="LocalVariable" UId="$instUid">
          <Component Name="$(ConvertTo-TiaXmlText $InstanceName)" />
        </Instance>
      </CallInfo>
    </Call>
"@)
    $Builder.PowerrailPins.Add("${callUid}:en")
    $callUid
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
            # A multi-instance of an FB rejects Remanence ("The attribute 'Remanence'
            # cannot be set"); instruction instances accept it. Emit it only where valid.
            $attrs = if ($s.PSObject.Properties['Block'] -and $s.Block) { '' }
                     else { ' Remanence="NonRetain" Accessibility="Public"' }
            [void]$sb.AppendLine("    <Member Name=""$(ConvertTo-TiaXmlText $s.Name)"" Datatype=""$dt""$attrs />")
        }
        [void]$sb.AppendLine('  </Section>')
    } else {
        # An FB called as a multi-instance must have a NON-EMPTY interface: an empty one
        # compiles to "A structure without components is not allowed" / "Invalid data type"
        # at the caller. Stateless layers (IOMap, Safety) have nothing to keep, so they get
        # one placeholder. The lab spike arrived at the same workaround.
        [void]$sb.AppendLine('  <Section Name="Static">')
        [void]$sb.AppendLine('    <Member Name="Reserved" Datatype="Bool" Remanence="NonRetain" Accessibility="Public" />')
        [void]$sb.AppendLine('  </Section>')
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
