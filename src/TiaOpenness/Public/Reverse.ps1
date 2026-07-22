# Reverse.ps1 - Export-TiaToSpec: turn an existing PLC into an editable spec (Phase 2).
# Emits tags + modules as CSV (editable), UDTs + blocks as SimaticML XML (faithful,
# round-trippable), and a JSON manifest that Invoke-TiaBuildFromSpec can rebuild from.

function Export-TiaToSpec {
    <#
    .SYNOPSIS
        Exports a PLC to a tia-autocode spec folder (CSV tags/modules + XML types/blocks
        + a project.json manifest) for adoption, version control, and round-trip.
    .PARAMETER OutDir
        Destination spec folder (created if missing).
    .PARAMETER PlcName
        Which PLC to export (defaults to the first).
    .EXAMPLE
        Connect-TiaPortal
        Export-TiaToSpec -OutDir .\adopted\PPS_SR_ -PlcName PLC_1
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutDir, [string]$PlcName, $Project)

    $plc = if ($PlcName) { Get-TiaPlc -Name $PlcName | Select-Object -First 1 } else { Get-TiaPlc | Select-Object -First 1 }
    if (-not $plc) { throw "No PLC found to export." }
    $sw = $plc.PlcSoftware
    $name = $plc.Name

    $dataDir  = Join-Path $OutDir 'data'
    $typesDir = Join-Path $OutDir 'types'
    $blockDir = Join-Path $OutDir 'blocks'
    foreach ($d in $dataDir,$typesDir,$blockDir) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

    # --- hardware: split CPU (-> orderNumber) from pluggable modules ---
    $items = @(Get-TiaModule -DeviceName $plc.Device)
    $cpu   = $items | Where-Object { $_.Name -eq $name -or $_.OrderNumber -match '5[0-9]{2}-' } | Select-Object -First 1
    $orderNumber = if ($cpu) { $cpu.OrderNumber } else { $null }
    $modRows = $items | Where-Object { $_ -ne $cpu -and $_.OrderNumber -notmatch '590-|595-' } |
        ForEach-Object { [pscustomobject]@{ Slot = $_.Slot; OrderNumber = ($_.OrderNumber -replace '^OrderNumber:',''); Name = $_.Name; Comment = '' } }
    $modCsv = Join-Path $dataDir "$name.modules.csv"
    if ($modRows) { $modRows | Sort-Object {[int]$_.Slot} | Export-Csv $modCsv -NoTypeInformation -Encoding ASCII }

    # --- tags -> CSV ---
    $tagRows = Get-TiaTag -Plc $sw | ForEach-Object {
        [pscustomobject]@{ TagTable = $_.Table; Name = $_.Name; DataType = $_.DataType; Address = $_.Address; Comment = $_.Comment; Retain = '' }
    }
    $tagCsv = Join-Path $dataDir "$name.tags.csv"
    if ($tagRows) { $tagRows | Export-Csv $tagCsv -NoTypeInformation -Encoding ASCII }

    # --- UDTs -> XML (faithful; round-trip via TypeGroup import) ---
    $typeFiles = New-Object System.Collections.Generic.List[string]
    foreach ($t in (Get-TiaType -Plc $sw)) {
        try {
            $fi = New-Object System.IO.FileInfo((Join-Path $typesDir ("{0}.xml" -f $t.Name)))
            if ($fi.Exists) { $fi.Delete() }
            $t.Type.Export($fi, [Siemens.Engineering.ExportOptions]::WithDefaults)
            $typeFiles.Add("types/$($t.Name).xml")
        } catch { Write-Warning "skip UDT $($t.Name): $($_.Exception.Message)" }
    }

    # --- blocks (OB/FB/FC/DB) -> XML ---
    $blockFiles = New-Object System.Collections.Generic.List[string]
    foreach ($b in (Get-TiaBlock -Plc $sw)) {
        try {
            $fi = New-Object System.IO.FileInfo((Join-Path $blockDir ("{0}.xml" -f $b.Name)))
            if ($fi.Exists) { $fi.Delete() }
            $b.Block.Export($fi, [Siemens.Engineering.ExportOptions]::WithDefaults)
            $blockFiles.Add("blocks/$($b.Name).xml")
        } catch { Write-Warning "skip block $($b.Name) (know-how/safety protected?): $($_.Exception.Message)" }
    }

    # --- manifest (project.json - build accepts JSON) ---
    $plcSpec = [ordered]@{ name = $name }
    if ($orderNumber) { $plcSpec.orderNumber = $orderNumber }
    if ($modRows)     { $plcSpec.modules  = @("data/$name.modules.csv") }
    if ($typeFiles.Count)  { $plcSpec.typesXml  = @($typeFiles) }
    if ($blockFiles.Count) { $plcSpec.blocksXml = @($blockFiles) }
    if ($tagRows)     { $plcSpec.tags = @("data/$name.tags.csv") }
    $plcSpec.compile = $true

    $manifest = [ordered]@{
        project = [ordered]@{ name = $name; path = "_out/$name" }
        portal  = [ordered]@{ new = $true; ui = $false }
        plcs    = @($plcSpec)
        build   = [ordered]@{ save = $true }
    }
    $manifestPath = Join-Path $OutDir 'project.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding ASCII

    [pscustomobject]@{
        OutDir = (Resolve-Path $OutDir).Path
        Plc = $name; OrderNumber = $orderNumber
        Tags = @($tagRows).Count; Modules = @($modRows).Count
        Types = $typeFiles.Count; Blocks = $blockFiles.Count
        Manifest = $manifestPath
    }
}
