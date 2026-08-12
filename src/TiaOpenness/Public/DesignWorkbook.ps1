# Write a design CSV snapshot back out as a single multi-tab .xlsx authoring workbook.
#
# The workbook is the human surface; design/csv stays the build input and the diffable
# safety change record. Export-TiaDesignWorkbook -> edit in Excel/Sheets ->
# Sync-TiaDesignSheet -Workbook -> design/csv. Round-trips losslessly (see the self-test).
#
# Dependency-free OOXML writer (System.IO.Compression + string XML): no Excel, no COM, no
# third-party module. Values are written as inline strings so there is no sharedStrings
# part to keep consistent - Import-TiaXlsx reads inlineStr.

function Export-TiaDesignWorkbook {
    <#
    .SYNOPSIS
        Pack a design CSV snapshot into one multi-tab .xlsx authoring workbook.
    .DESCRIPTION
        Emits every tab in schema order with a frozen, bold header row, sized columns and
        dropdown validation on the closed-enum columns - so the safety-critical fields
        (Polarity, Verified, Instruction, Kind, SensorEval, Include) cannot be typo'd into
        a value the validator will later reject.

        Derived data is NOT written: addresses, tag names and member paths come from the
        build, so the workbook never becomes a second source of truth for them.
    .PARAMETER Path
        Folder of <TabName>.csv (default: .\design\csv).
    .PARAMETER Out
        Target .xlsx (default: <parent of Path>\Design.xlsx).
    .PARAMETER Force
        Overwrite an existing workbook. Without it, an existing file is an error - the
        workbook is hand-edited, so silently replacing it would discard that work.
    .EXAMPLE
        Export-TiaDesignWorkbook -Path .\design\csv -Out .\design\SR_PPS_Design.xlsx
    #>
    [CmdletBinding()]
    param(
        [string]$Path = '.\design\csv',
        [string]$Out,
        [switch]$Force
    )
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path $Path)) { throw "No CSV snapshot at $Path" }
    if (-not $Out) { $Out = Join-Path (Split-Path -Parent $Path) 'Design.xlsx' }
    $Out = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Out)
    if ((Test-Path $Out) -and -not $Force) {
        throw "Workbook already exists: $Out (use -Force to overwrite - it is hand-edited)"
    }

    # tab order: by the numeric prefix, so the workbook reads 00_README .. 35_Outputs
    $order = @(@('00_README') + @($script:TiaSheetKnownHeaders.Keys) | Select-Object -Unique | Sort-Object)
    $tabs = @()
    foreach ($t in ($order | Select-Object -Unique)) {
        $f = Join-Path $Path "$t.csv"
        if (-not (Test-Path $f)) { continue }
        $rows = @(Import-Csv $f)
        $cols = if ($rows.Count) { @($rows[0].PSObject.Properties.Name) }
                elseif ($script:TiaSheetKnownHeaders.Contains($t)) { @($script:TiaSheetKnownHeaders[$t]) }
                else { @((Get-Content -TotalCount 1 $f) -split ',' | ForEach-Object { $_.Trim('"') }) }
        $tabs += [pscustomobject]@{ Name = $t; Cols = $cols; Rows = $rows }
    }
    if (-not $tabs.Count) { throw "No tab CSVs found in $Path" }

    function Esc([string]$s) {
        if ($null -eq $s) { return '' }
        $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
    }

    $sheetXml = @{}
    foreach ($tab in $tabs) {
        $cols = $tab.Cols
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
        # freeze the header row - these tabs are long and get scrolled a lot
        [void]$sb.Append('<sheetViews><sheetView workbookViewId="0">')
        [void]$sb.Append('<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>')
        [void]$sb.Append('</sheetView></sheetViews>')

        # width from the widest of header and a sample of values, clamped to something sane
        [void]$sb.Append('<cols>')
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $w = $cols[$i].Length
            $seen = 0
            foreach ($r in $tab.Rows) {
                $v = [string]$r.($cols[$i])
                if ($v.Length -gt $w) { $w = $v.Length }
                if (++$seen -ge 200) { break }
            }
            $w = [Math]::Max(9, [Math]::Min(52, $w + 2))
            [void]$sb.Append(('<col min="{0}" max="{0}" width="{1}" customWidth="1"/>' -f ($i + 1), $w))
        }
        [void]$sb.Append('</cols><sheetData>')

        [void]$sb.Append('<row r="1">')
        for ($i = 0; $i -lt $cols.Count; $i++) {
            [void]$sb.Append(('<c r="{0}1" s="1" t="inlineStr"><is><t xml:space="preserve">{1}</t></is></c>' -f
                (ConvertTo-TiaXlsxColumn -Index $i), (Esc $cols[$i])))
        }
        [void]$sb.Append('</row>')

        $rn = 1
        foreach ($r in $tab.Rows) {
            $rn++
            [void]$sb.Append(('<row r="{0}">' -f $rn))
            for ($i = 0; $i -lt $cols.Count; $i++) {
                $v = [string]$r.($cols[$i])
                if ([string]::IsNullOrEmpty($v)) { continue }
                [void]$sb.Append(('<c r="{0}{1}" t="inlineStr"><is><t xml:space="preserve">{2}</t></is></c>' -f
                    (ConvertTo-TiaXlsxColumn -Index $i), $rn, (Esc $v)))
            }
            [void]$sb.Append('</row>')
        }
        [void]$sb.Append('</sheetData>')

        # dropdowns on closed enums - stops a typo becoming a validator failure later
        $dv = @()
        foreach ($k in $script:TiaSheetEnums.Keys) {
            $kt, $kc = $k -split '\.', 2
            if ($kt -ne $tab.Name) { continue }
            $ci = [array]::IndexOf($cols, $kc)
            if ($ci -lt 0) { continue }
            $letter = ConvertTo-TiaXlsxColumn -Index $ci
            $list = ($script:TiaSheetEnums[$k] -join ',')
            $dv += ('<dataValidation type="list" allowBlank="1" showInputMessage="1" ' +
                    'showErrorMessage="1" sqref="{0}2:{0}5000"><formula1>"{1}"</formula1></dataValidation>' -f
                    $letter, (Esc $list))
        }
        foreach ($vc in @('Verified','Include','InInterlock','FailsafeCompliant')) {
            $ci = [array]::IndexOf($cols, $vc)
            if ($ci -lt 0) { continue }
            if ($script:TiaSheetEnums.ContainsKey("$($tab.Name).$vc")) { continue }
            $letter = ConvertTo-TiaXlsxColumn -Index $ci
            $dv += ('<dataValidation type="list" allowBlank="1" showInputMessage="1" ' +
                    'showErrorMessage="1" sqref="{0}2:{0}5000"><formula1>"Yes,No"</formula1></dataValidation>' -f $letter)
        }
        if ($dv.Count) {
            [void]$sb.Append(('<dataValidations count="{0}">{1}</dataValidations>' -f $dv.Count, ($dv -join '')))
        }
        [void]$sb.Append('</worksheet>')
        $sheetXml[$tab.Name] = $sb.ToString()
    }

    $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>' +
        '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>' +
        '<fills count="2"><fill><patternFill patternType="none"/></fill>' +
        '<fill><patternFill patternType="gray125"/></fill></fills>' +
        '<borders count="1"><border/></borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>' +
        '</styleSheet>'

    $ct = New-Object System.Text.StringBuilder
    [void]$ct.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$ct.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
    [void]$ct.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    [void]$ct.Append('<Default Extension="xml" ContentType="application/xml"/>')
    [void]$ct.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    [void]$ct.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')

    $wb = New-Object System.Text.StringBuilder
    [void]$wb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$wb.Append('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ')
    [void]$wb.Append('xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>')
    $wr = New-Object System.Text.StringBuilder
    [void]$wr.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$wr.Append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')

    for ($i = 0; $i -lt $tabs.Count; $i++) {
        $id = $i + 1
        [void]$ct.Append(('<Override PartName="/xl/worksheets/sheet{0}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' -f $id))
        [void]$wb.Append(('<sheet name="{0}" sheetId="{1}" r:id="rId{1}"/>' -f (Esc $tabs[$i].Name), $id))
        [void]$wr.Append(('<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{0}.xml"/>' -f $id))
    }
    $styleId = $tabs.Count + 1
    [void]$ct.Append('</Types>')
    [void]$wb.Append('</sheets></workbook>')
    [void]$wr.Append(('<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' -f $styleId))
    [void]$wr.Append('</Relationships>')

    $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $dir = Split-Path -Parent $Out
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    # write to a temp file and move into place, so a failure never leaves a half-written
    # workbook where the design used to be
    $tmp = "$Out.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $zip = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        function Add-Entry($archive, $name, $text) {
            $e = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $s = $e.Open()
            try {
                $bytes = $utf8.GetBytes($text)
                $s.Write($bytes, 0, $bytes.Length)
            } finally { $s.Dispose() }
        }
        Add-Entry $zip '[Content_Types].xml' $ct.ToString()
        Add-Entry $zip '_rels/.rels' $rels
        Add-Entry $zip 'xl/workbook.xml' $wb.ToString()
        Add-Entry $zip 'xl/_rels/workbook.xml.rels' $wr.ToString()
        Add-Entry $zip 'xl/styles.xml' $styles
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            Add-Entry $zip ('xl/worksheets/sheet{0}.xml' -f ($i + 1)) $sheetXml[$tabs[$i].Name]
        }
    } finally { $zip.Dispose() }
    Move-Item -Force $tmp $Out

    [pscustomobject]@{
        Ok    = $true
        Path  = $Out
        Tabs  = @($tabs | ForEach-Object { [pscustomobject]@{ Tab = $_.Name; Rows = $_.Rows.Count; Columns = $_.Cols.Count } })
    }
}
