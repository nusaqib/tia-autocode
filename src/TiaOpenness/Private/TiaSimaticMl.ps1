# SimaticML emitters for the sheet-driven builder.
#
# These produce the canonical forms proven live in the PPS_SR_LAB spike. SimaticML is
# ORDER-SENSITIVE: elements must appear in the order TIA's schema expects or the import is
# rejected with a misleading "invalid child element". Do not reorder without re-testing.

function ConvertTo-TiaXmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Format-TiaMlDatatype {
    <#
    .SYNOPSIS
        Datatype as SimaticML wants it - UDT references are quoted (as &quot; entities).
    #>
    param([string]$Datatype)
    $t = ([string]$Datatype).Trim().Trim('"')
    if (Test-TiaPrimitive $t) { return $t }
    '&quot;' + $t + '&quot;'
}

function New-TiaMlMultilingualText {
    param([int]$Id, [string]$Composition, [string]$Text = '')
    $t = if ($Text) { "<Text>$(ConvertTo-TiaXmlText $Text)</Text>" } else { '<Text />' }
    @"
      <MultilingualText ID="$Id" CompositionName="$Composition">
        <ObjectList>
          <MultilingualTextItem ID="$($Id + 1)" CompositionName="Items">
            <AttributeList>
              <Culture>en-US</Culture>
              $t
            </AttributeList>
          </MultilingualTextItem>
        </ObjectList>
      </MultilingualText>
"@
}

function New-TiaUdtXml {
    <#
    .SYNOPSIS
        Canonical PLC data type (SW.Types.PlcStruct), optionally fail-safe compliant.
    .DESCRIPTION
        IsFailsafeCompliant is the flag that lets a UDT be used in an F-block interface,
        and it CANNOT be set from SCL - an SCL-created UDT compiles fine on its own but
        the safety compile then rejects every F-DB member that uses it with
        "The type <X> is not permitted in the fail-safe block interface."
    .PARAMETER Members
        Rows with Name, Datatype and optional Comment.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Members,
        [bool]$FailsafeCompliant = $true,
        [string]$Version = 'V19'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<Document>')
    [void]$sb.AppendLine("  <Engineering version=""$Version"" />")
    [void]$sb.AppendLine('  <SW.Types.PlcStruct ID="0">')
    [void]$sb.AppendLine('    <AttributeList>')
    [void]$sb.AppendLine('      <Interface><Sections xmlns="http://www.siemens.com/automation/Openness/SW/Interface/v5">')
    [void]$sb.AppendLine('  <Section Name="None">')
    foreach ($m in $Members) {
        $dt = Format-TiaMlDatatype $m.Datatype
        $nm = ConvertTo-TiaXmlText $m.Name
        if ($m.Comment) {
            [void]$sb.AppendLine("    <Member Name=""$nm"" Datatype=""$dt"">")
            [void]$sb.AppendLine('      <Comment>')
            [void]$sb.AppendLine("        <MultiLanguageText Lang=""en-US"">$(ConvertTo-TiaXmlText $m.Comment)</MultiLanguageText>")
            [void]$sb.AppendLine('      </Comment>')
            [void]$sb.AppendLine('    </Member>')
        } else {
            [void]$sb.AppendLine("    <Member Name=""$nm"" Datatype=""$dt"" />")
        }
    }
    [void]$sb.AppendLine('  </Section>')
    [void]$sb.AppendLine('</Sections></Interface>')
    [void]$sb.AppendLine("      <IsFailsafeCompliant>$($FailsafeCompliant.ToString().ToLowerInvariant())</IsFailsafeCompliant>")
    [void]$sb.AppendLine("      <Name>$(ConvertTo-TiaXmlText $Name)</Name>")
    [void]$sb.AppendLine('      <Namespace />')
    [void]$sb.AppendLine('    </AttributeList>')
    [void]$sb.AppendLine('    <ObjectList>')
    [void]$sb.Append((New-TiaMlMultilingualText -Id 1 -Composition 'Comment'))
    [void]$sb.Append((New-TiaMlMultilingualText -Id 3 -Composition 'Title'))
    [void]$sb.AppendLine('    </ObjectList>')
    [void]$sb.AppendLine('  </SW.Types.PlcStruct>')
    [void]$sb.AppendLine('</Document>')
    $sb.ToString()
}

function Import-TiaTypeXml {
    <#
    .SYNOPSIS
        Import a PLC data type from SimaticML (TypeGroup.Types.Import).
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$Overwrite, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    $fi = New-Object System.IO.FileInfo($Path)
    $opt = if ($Overwrite) { [Siemens.Engineering.ImportOptions]::Override } else { [Siemens.Engineering.ImportOptions]::None }
    $sw.TypeGroup.Types.Import($fi, $opt) | Out-Null
    $Path
}

function New-TiaFailsafeDbXml {
    <#
    .SYNOPSIS
        Canonical formal F-DB (SW.Blocks.GlobalDB, ProgrammingLanguage F_DB).
    .DESCRIPTION
        ProgrammingLanguage=F_DB is what makes the block fail-safe, and it can only be set
        through XML - an SCL-created DB is an ordinary DB, which the safety program will
        not accept. Members are top-level only: TIA expands nested UDT members itself on
        import, so they must not be written out.
    .PARAMETER Members
        Rows with Name, Datatype and optional Comment.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)]$Members,
        [string]$Version = 'V19'
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<Document>')
    [void]$sb.AppendLine("  <Engineering version=""$Version"" />")
    [void]$sb.AppendLine('  <SW.Blocks.GlobalDB ID="0">')
    [void]$sb.AppendLine('    <AttributeList>')
    [void]$sb.AppendLine('      <AutoNumber>false</AutoNumber>')
    [void]$sb.AppendLine('      <HeaderAuthor />')
    [void]$sb.AppendLine('      <HeaderFamily />')
    [void]$sb.AppendLine('      <HeaderName />')
    [void]$sb.AppendLine('      <HeaderVersion>0.1</HeaderVersion>')
    [void]$sb.AppendLine('      <Interface><Sections xmlns="http://www.siemens.com/automation/Openness/SW/Interface/v5">')
    [void]$sb.AppendLine('  <Section Name="Static">')
    foreach ($m in $Members) {
        $dt = Format-TiaMlDatatype $m.Datatype
        $nm = ConvertTo-TiaXmlText $m.Name
        if ($m.Comment) {
            [void]$sb.AppendLine("    <Member Name=""$nm"" Datatype=""$dt"" Remanence=""NonRetain"" Accessibility=""Public"">")
            [void]$sb.AppendLine('      <Comment>')
            [void]$sb.AppendLine("        <MultiLanguageText Lang=""en-US"">$(ConvertTo-TiaXmlText $m.Comment)</MultiLanguageText>")
            [void]$sb.AppendLine('      </Comment>')
            [void]$sb.AppendLine('    </Member>')
        } else {
            [void]$sb.AppendLine("    <Member Name=""$nm"" Datatype=""$dt"" Remanence=""NonRetain"" Accessibility=""Public"" />")
        }
    }
    [void]$sb.AppendLine('  </Section>')
    [void]$sb.AppendLine('</Sections></Interface>')
    [void]$sb.AppendLine('      <MemoryLayout>Optimized</MemoryLayout>')
    [void]$sb.AppendLine("      <Name>$(ConvertTo-TiaXmlText $Name)</Name>")
    [void]$sb.AppendLine('      <Namespace />')
    [void]$sb.AppendLine("      <Number>$Number</Number>")
    [void]$sb.AppendLine('      <ProgrammingLanguage>F_DB</ProgrammingLanguage>')
    [void]$sb.AppendLine('    </AttributeList>')
    [void]$sb.AppendLine('    <ObjectList>')
    [void]$sb.Append((New-TiaMlMultilingualText -Id 1 -Composition 'Comment'))
    [void]$sb.Append((New-TiaMlMultilingualText -Id 3 -Composition 'Title'))
    [void]$sb.AppendLine('    </ObjectList>')
    [void]$sb.AppendLine('  </SW.Blocks.GlobalDB>')
    [void]$sb.AppendLine('</Document>')
    $sb.ToString()
}

function Save-TiaMlDocument {
    <#
    .SYNOPSIS
        Write SimaticML to a UTF-8 file with BOM (TIA rejects BOM-less imports).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Xml)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Xml, (New-Object System.Text.UTF8Encoding($true)))
    $Path
}
