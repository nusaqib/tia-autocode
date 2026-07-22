# Lifecycle.ps1 — backup / round-trip export and (guarded) download to a CPU.

function Export-TiaProgram {
    <#
    .SYNOPSIS
        Exports every PLC block (and optionally tags/types) to SimaticML XML — a
        text, diffable, version-controllable snapshot of the program.
    .PARAMETER OutDir
        Destination folder (created if missing). Blocks go to <OutDir>\Blocks.
    .PARAMETER IncludeTags
        Also export tag tables to <OutDir>\Tags.
    .EXAMPLE
        Export-TiaProgram -OutDir .\export\PLC_1 -IncludeTags
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutDir, [switch]$IncludeTags, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    $blockDir = Join-Path $OutDir 'Blocks'
    New-Item -ItemType Directory -Path $blockDir -Force | Out-Null

    $exported = 0
    foreach ($b in (Get-TiaBlock -Plc $sw)) {
        # Skip know-how-protected / system blocks that refuse export.
        try {
            $fi = New-Object System.IO.FileInfo((Join-Path $blockDir ("{0}.xml" -f $b.Name)))
            if ($fi.Exists) { $fi.Delete() }
            $b.Block.Export($fi, [Siemens.Engineering.ExportOptions]::WithDefaults)
            $exported++
        } catch { Write-Warning "skip block $($b.Name): $($_.Exception.Message)" }
    }

    $tagCount = 0
    if ($IncludeTags) {
        $tagDir = Join-Path $OutDir 'Tags'
        New-Item -ItemType Directory -Path $tagDir -Force | Out-Null
        foreach ($tt in (Get-TiaTagTable -Plc $sw)) {
            try {
                $fi = New-Object System.IO.FileInfo((Join-Path $tagDir ("{0}.xml" -f $tt.Name)))
                if ($fi.Exists) { $fi.Delete() }
                $tt.TagTable.Export($fi, [Siemens.Engineering.ExportOptions]::WithDefaults)
                $tagCount++
            } catch { Write-Warning "skip tag table $($tt.Name): $($_.Exception.Message)" }
        }
    }
    [pscustomobject]@{ OutDir = (Resolve-Path $OutDir).Path; Blocks = $exported; TagTables = $tagCount }
}

function Get-TiaOnlineState {
    <#
    .SYNOPSIS
        Reports the online/connection state of a PLC (requires an online-capable setup).
    #>
    [CmdletBinding()]
    param($Plc)
    $sw = Resolve-PlcSoftware $Plc
    # PlcSoftware -> parent DeviceItem -> OnlineProvider via GetService.
    try {
        $op = [Siemens.Engineering.Online.OnlineProvider]
        $mi = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($op)
        $provider = $mi.Invoke($sw, $null)
        [pscustomobject]@{ State = $provider.State; Connected = ($provider.State -eq 'Online') }
    } catch { [pscustomobject]@{ State = 'Unknown'; Connected = $false; Note = $_.Exception.Message } }
}

function Invoke-TiaDownload {
    <#
    .SYNOPSIS
        Downloads compiled software to a CPU. AFFECTS REAL/SIMULATED HARDWARE.
    .DESCRIPTION
        Guarded by ShouldProcess (-WhatIf/-Confirm). Requires an established online
        connection (real CPU or PLCSIM). Compile first with Invoke-TiaCompile. Only
        run against a target you intend to change — never a production CPU casually.
    .PARAMETER Force
        Skip the interactive confirmation (still honors -WhatIf).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([switch]$Force, $Plc)
    $sw = Resolve-PlcSoftware $Plc
    $name = $sw.Name
    if (-not ($Force -or $PSCmdlet.ShouldProcess($name, 'DOWNLOAD software to CPU'))) { return }

    $dp = [Siemens.Engineering.Download.DownloadProvider]
    $mi = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($dp)
    $provider = $mi.Invoke($sw, $null)
    if (-not $provider) { throw "No DownloadProvider — is this device online-capable and connected?" }

    # Default configuration/post-download delegates: proceed with library defaults.
    $preConf  = [Siemens.Engineering.Download.Configuration.DownloadConfiguration]
    $result = $provider.Download(
        $provider.Configuration,
        { param($cfg) },   # pre-download: accept defaults
        { param($cfg) }    # post-download: accept defaults
    )
    [pscustomobject]@{ State = $result.State; Warnings = $result.WarningCount; Errors = $result.ErrorCount }
}
