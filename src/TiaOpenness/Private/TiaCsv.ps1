# CSV text helpers for design-sheet ingestion (see Public/DesignSheet.ps1).

function ConvertTo-TiaCsvText {
    <#
    .SYNOPSIS
        Render a jagged array of row-arrays (Sheets API 'values') as CSV text.
    #>
    param($Values)
    $sb = New-Object System.Text.StringBuilder
    foreach ($row in $Values) {
        $cells = foreach ($c in $row) {
            $s = [string]$c
            if ($s -match '[",\r\n]') { '"' + ($s -replace '"','""') + '"' } else { $s }
        }
        [void]$sb.AppendLine(($cells -join ','))
    }
    $sb.ToString()
}
