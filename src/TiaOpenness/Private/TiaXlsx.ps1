# TiaXlsx.ps1 - dependency-free .xlsx reader (OOXML: unzip + parse XML).
# No Excel, no COM, no external module - reads the spreadsheetml parts directly so it
# runs on a clean CI runner. Returns rows shaped exactly like Import-Csv (PSCustomObjects
# keyed by the header row), so the rest of the engine treats CSV and XLSX identically.

$script:TiaXlsxMainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:TiaXlsxRelNs  = 'http://schemas.openxmlformats.org/package/2006/relationships'

function Get-TiaXlsxColIndex {
    # 'A' -> 0, 'B' -> 1, ... 'AA' -> 26. Accepts a cell ref like 'AB12' (letters only used).
    param([string]$Ref)
    $letters = ($Ref -replace '\d','').ToUpperInvariant()
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - [int][char]'A' + 1) }
    $n - 1
}

function Open-TiaXlsxArchive {
    <#
    .SYNOPSIS
        Open an .xlsx for reading even while it is open in Excel.
    .DESCRIPTION
        ZipFile::OpenRead asks for FileShare.Read, which Excel refuses on a workbook it has
        open - so the whole design workflow (sync, stale check) used to die with a sharing
        violation whenever the author had the book on screen. Requesting ReadWrite sharing
        reads the bytes Excel last wrote to disk.

        That is the honest thing to read: it is exactly what a build would consume. It is
        NOT what is on the author's screen - unsaved edits are invisible - so callers warn
        when the ~$ lock file is present. Disposing the archive disposes the stream.
    #>
    param([Parameter(Mandatory)][string]$Path)
    # ZipArchive itself lives in System.IO.Compression; ZipFile in .FileSystem. Both.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read, $false)
    } catch { $fs.Dispose(); throw }
}

function Get-TiaSharedFileHash {
    <#
    .SYNOPSIS
        SHA256 of a file, readable even while another process holds it open.
    .DESCRIPTION
        Get-FileHash fails on a workbook open in Excel, which would abort a sync that had
        already written every CSV correctly. Returns '' if the file cannot be read at all -
        this is a provenance record, not a gate.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
                  [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '' }
            finally { $sha.Dispose() }
        } finally { $fs.Dispose() }
    } catch { '' }
}

function Test-TiaSubnetMask {
    <#
    .SYNOPSIS
        Return a complaint string when a dotted quad is not a usable IPv4 subnet mask,
        or '' when it is fine.
    .DESCRIPTION
        A mask is N leading 1-bits then all 0-bits. 255.255.255.1 is a well-formed dotted
        quad and a nonsense mask - the failure mode of dragging a fill handle down a
        Subnet_Mask column in Excel. /31 and /32 are rejected too: they leave no usable
        host range for an IO system.
    #>
    param([Parameter(Mandatory)][string]$Mask)
    $parts = $Mask.Split('.')
    if ($parts.Count -ne 4) { return 'is not a dotted quad' }
    $bits = 0
    foreach ($p in $parts) {
        $o = 0
        if (-not [int]::TryParse($p, [ref]$o) -or $o -lt 0 -or $o -gt 255) { return 'is not a dotted quad' }
        $bits = ($bits -shl 8) -bor $o
    }
    if ($bits -eq 0) { return 'is all zeroes' }
    # ones followed by zeroes <=> (~mask + 1) is a power of two
    $inv = (-bnot $bits) -band 0xFFFFFFFF
    if ((($inv + 1) -band $inv) -ne 0) { return 'is not contiguous (a mask is 1-bits then 0-bits)' }
    $len = 0; $t = $bits
    while ($t -ne 0) { $len += ($t -shr 31) -band 1; $t = ($t -shl 1) -band 0xFFFFFFFF }
    if ($len -gt 30) { return "is /$len - no usable host range" }
    ''
}

function Test-TiaXlsxOpenInExcel {
    <#
    .SYNOPSIS
        True when Excel's owner-lock file for this workbook exists (book is open somewhere).
    #>
    param([Parameter(Mandatory)][string]$Path)
    $lock = Join-Path (Split-Path -Parent $Path) ('~$' + (Split-Path -Leaf $Path))
    Test-Path -LiteralPath $lock
}

function Read-TiaXlsxPart {
    param($Zip, [string]$Name)
    $entry = $Zip.Entries | Where-Object { $_.FullName -eq $Name } | Select-Object -First 1
    if (-not $entry) { return $null }
    $sr = New-Object System.IO.StreamReader($entry.Open())
    try { $sr.ReadToEnd() } finally { $sr.Dispose() }
}

function Import-TiaXlsx {
    <#
    .SYNOPSIS
        Reads a worksheet from an .xlsx workbook into rows (like Import-Csv), no Excel needed.
    .DESCRIPTION
        Parses the OOXML parts (workbook.xml, sharedStrings.xml, worksheets/*.xml) straight
        out of the .xlsx zip. The first non-empty row is treated as the header; each later
        row becomes a PSCustomObject keyed by those headers. Blank trailing rows are skipped.
    .PARAMETER Path
        Path to the .xlsx file.
    .PARAMETER Sheet
        Worksheet name (tab). Defaults to the first sheet in the workbook.
    .EXAMPLE
        Import-TiaXlsx -Path .\book.xlsx -Sheet Tags
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Sheet)

    if (-not (Test-Path $Path)) { throw "Workbook not found: $Path" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $full = (Resolve-Path $Path).Path
    $zip = Open-TiaXlsxArchive -Path $full
    try {
        # 1) shared strings (0-based). May be absent if the sheet has no text cells.
        $shared = New-Object System.Collections.Generic.List[string]
        $ssXml = Read-TiaXlsxPart $zip 'xl/sharedStrings.xml'
        if ($ssXml) {
            $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($ssXml)
            $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('d',$script:TiaXlsxMainNs)
            foreach ($si in $doc.SelectNodes('//d:si',$ns)) {
                # <si> may be a single <t> or rich text runs <r><t>..; concatenate all <t>.
                $texts = $si.SelectNodes('.//d:t',$ns)
                $sb = ''
                foreach ($t in $texts) { $sb += $t.InnerText }
                [void]$shared.Add($sb)
            }
        }

        # 2) workbook -> sheet name -> rId, then rels rId -> worksheet part.
        $wbXml = Read-TiaXlsxPart $zip 'xl/workbook.xml'
        if (-not $wbXml) { throw "Not a valid .xlsx (missing xl/workbook.xml): $Path" }
        $wb = New-Object System.Xml.XmlDocument; $wb.LoadXml($wbXml)
        $wbns = New-Object System.Xml.XmlNamespaceManager($wb.NameTable)
        $wbns.AddNamespace('d',$script:TiaXlsxMainNs); $wbns.AddNamespace('r','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $sheets = @()
        foreach ($s in $wb.SelectNodes('//d:sheet',$wbns)) {
            $rid = $s.GetAttribute('id','http://schemas.openxmlformats.org/officeDocument/2006/relationships')
            $sheets += [pscustomobject]@{ Name = $s.GetAttribute('name'); RId = $rid }
        }
        if (-not $sheets.Count) { throw "Workbook has no sheets: $Path" }

        $relXml = Read-TiaXlsxPart $zip 'xl/_rels/workbook.xml.rels'
        $ridToTarget = @{}
        if ($relXml) {
            $rd = New-Object System.Xml.XmlDocument; $rd.LoadXml($relXml)
            $rns = New-Object System.Xml.XmlNamespaceManager($rd.NameTable); $rns.AddNamespace('p',$script:TiaXlsxRelNs)
            foreach ($rel in $rd.SelectNodes('//p:Relationship',$rns)) {
                $ridToTarget[$rel.GetAttribute('Id')] = $rel.GetAttribute('Target')
            }
        }

        $target = $null
        if ($Sheet) {
            $hit = $sheets | Where-Object { $_.Name -eq $Sheet } | Select-Object -First 1
            if (-not $hit) { throw "Sheet '$Sheet' not found in $Path. Available: $(( $sheets.Name) -join ', ')" }
            $target = $ridToTarget[$hit.RId]
        } else {
            $target = $ridToTarget[$sheets[0].RId]
        }
        if (-not $target) { throw "Could not resolve worksheet part for sheet '$Sheet' in $Path." }
        $target = $target -replace '^/xl/','' -replace '^/',''       # normalize
        if ($target -notlike 'xl/*') { $target = "xl/$target" }

        # 3) parse the worksheet rows/cells.
        $wsXml = Read-TiaXlsxPart $zip $target
        if (-not $wsXml) { throw "Worksheet part '$target' missing in $Path." }
        $ws = New-Object System.Xml.XmlDocument; $ws.LoadXml($wsXml)
        $wsns = New-Object System.Xml.XmlNamespaceManager($ws.NameTable); $wsns.AddNamespace('d',$script:TiaXlsxMainNs)

        $matrix = New-Object System.Collections.Generic.List[object]
        foreach ($row in $ws.SelectNodes('//d:sheetData/d:row',$wsns)) {
            $cells = @{}
            $maxCol = -1
            foreach ($c in $row.SelectNodes('d:c',$wsns)) {
                $ref = $c.GetAttribute('r'); $t = $c.GetAttribute('t')
                $ci = if ($ref) { Get-TiaXlsxColIndex $ref } else { $maxCol + 1 }
                if ($ci -gt $maxCol) { $maxCol = $ci }
                $val = ''
                if ($t -eq 's') {
                    $vn = $c.SelectSingleNode('d:v',$wsns)
                    if ($vn) { $idx = [int]$vn.InnerText; if ($idx -ge 0 -and $idx -lt $shared.Count) { $val = $shared[$idx] } }
                } elseif ($t -eq 'inlineStr') {
                    $isn = $c.SelectSingleNode('d:is',$wsns); if ($isn) { $val = ($isn.SelectNodes('.//d:t',$wsns) | ForEach-Object { $_.InnerText }) -join '' }
                } else {
                    $vn = $c.SelectSingleNode('d:v',$wsns); if ($vn) { $val = $vn.InnerText }
                }
                $cells[$ci] = $val
            }
            $arr = @()
            for ($i = 0; $i -le $maxCol; $i++) { if ($cells.ContainsKey($i)) { $arr += $cells[$i] } else { $arr += '' } }
            $matrix.Add($arr)
        }

        # 4) header row = first row with any non-empty cell; build objects from the rest.
        $headerIdx = -1
        for ($i = 0; $i -lt $matrix.Count; $i++) {
            if (@($matrix[$i] | Where-Object { "$_".Trim() -ne '' }).Count) { $headerIdx = $i; break }
        }
        if ($headerIdx -lt 0) { return @() }
        $headers = @($matrix[$headerIdx] | ForEach-Object { "$_".Trim() })

        $out = New-Object System.Collections.Generic.List[object]
        for ($i = $headerIdx + 1; $i -lt $matrix.Count; $i++) {
            $r = $matrix[$i]
            if (-not @($r | Where-Object { "$_".Trim() -ne '' }).Count) { continue }   # skip blank rows
            $o = [ordered]@{}
            for ($c = 0; $c -lt $headers.Count; $c++) {
                $h = $headers[$c]; if (-not $h) { continue }
                $o[$h] = if ($c -lt $r.Count) { $r[$c] } else { '' }
            }
            $out.Add([pscustomobject]$o)
        }
        return $out
    } finally { $zip.Dispose() }
}

function Split-TiaTableRef {
    # 'data/book.xlsx#Tags' -> @{ Path='data/book.xlsx'; Sheet='Tags' }. No '#': Sheet=$null.
    param([string]$Ref)
    if ($Ref -match '^(?<p>.+\.xlsx)#(?<s>.+)$') { return @{ Path = $Matches.p; Sheet = $Matches.s } }
    return @{ Path = $Ref; Sheet = $null }
}

function Resolve-TiaRef {
    # Resolve a data ref (csv or 'book.xlsx#Sheet') to its file path, relative to BaseDir.
    param([string]$Ref, [string]$BaseDir)
    $split = Split-TiaTableRef $Ref
    $p = $split.Path
    if (-not [System.IO.Path]::IsPathRooted($p) -and $BaseDir) { $p = Join-Path $BaseDir $p }
    $p
}

function Read-TiaRows {
    # Dispatcher: read tabular rows from a .csv or .xlsx[#Sheet] ref (relative to BaseDir).
    param([Parameter(Mandatory)][string]$Ref, [string]$BaseDir)
    $split = Split-TiaTableRef $Ref
    $path = $split.Path
    if (-not [System.IO.Path]::IsPathRooted($path) -and $BaseDir) { $path = Join-Path $BaseDir $path }
    if ($path -match '\.xlsx$') { @(Import-TiaXlsx -Path $path -Sheet $split.Sheet) }
    else { @(Import-Csv $path) }
}

function ConvertTo-TiaXlsxColumn {
    <#
    .SYNOPSIS
        0-based column index -> A, B, ... Z, AA, AB ... (OOXML cell references).
    #>
    param([Parameter(Mandatory)][int]$Index)
    $s = ''
    $n = $Index + 1
    while ($n -gt 0) {
        $r = ($n - 1) % 26
        $s = [char](65 + $r) + $s
        $n = [int](($n - 1) / 26)
    }
    $s
}
