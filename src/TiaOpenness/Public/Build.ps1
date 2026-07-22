# Build.ps1 - declarative project generator.
# Turn a JSON/hashtable spec into a materialized TIA program: project -> device(s)
# -> tags -> UDTs -> code blocks -> data blocks -> compile, and optional HMI screens.
# This is the "automatic coding platform" entry point.

function Invoke-TiaBuildFromSpec {
    <#
    .SYNOPSIS
        Builds (or updates) a TIA project from a declarative spec.
    .PARAMETER Path
        Path to a JSON spec file. (Alternatively pass -Spec a hashtable/object.)
    .PARAMETER Spec
        Spec object (from ConvertFrom-Json or a PowerShell hashtable).
    .DESCRIPTION
        Spec shape (all sections optional except what you want built):
          {
            "portal":  { "new": true, "ui": false },
            "project": { "name": "Demo", "path": "C:\\temp\\Demo", "openIfExists": true },
            "plcs": [{
              "name": "PLC_1",
              "orderNumber": "OrderNumber:6ES7 512-1SN03-0AB0/V3.0",
              "tagTables": [{ "name":"IO", "tags":[
                  {"name":"Start_PB","dataType":"Bool","address":"%I0.0","comment":"start"} ]}],
              "types":  [{ "scl":"TYPE \"MotorData\" STRUCT Speed:Real; END_STRUCT; END_TYPE" }],
              "blocks": [{ "sclFile":"templates\\Scale.scl" }, { "scl":"FUNCTION_BLOCK ..." }],
              "dataBlocks": [{ "name":"Motor1_DB", "ofType":"MotorStarter" }],
              "compile": true
            }],
            "hmis": [{ "name":"HMI_1", "screens":[{ "importXml":"screens\\Start.xml" }] }],
            "save": true
          }
    .EXAMPLE
        Invoke-TiaBuildFromSpec -Path .\specs\demo.json
    #>
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory, ParameterSetName='Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName='Spec')]$Spec,
        [string]$BaseDir
    )
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path $Path)) { throw "Spec file not found: $Path" }
        if (-not $BaseDir) { $BaseDir = Split-Path (Resolve-Path $Path) -Parent }
        $Spec = Get-Content $Path -Raw | ConvertFrom-Json
    }
    if (-not $BaseDir) { $BaseDir = (Get-Location).Path }

    $report = [ordered]@{ Steps = New-Object System.Collections.Generic.List[string]; Errors = New-Object System.Collections.Generic.List[string] }
    function Step($m){ $report.Steps.Add($m); Write-Verbose $m; Write-Host "  + $m" }
    function Fail($m){ $report.Errors.Add($m); Write-Warning $m }
    function ResolvePath($p){ if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $BaseDir $p } }

    # 1) Portal
    if ($Spec.portal -and $Spec.portal.new) {
        $ui = [bool]$Spec.portal.ui
        Connect-TiaPortal -New -WithUserInterface:$ui | Out-Null
        Step "started new Portal (ui=$ui)"
    } elseif (-not (Get-TiaOpennessState).Loaded -or -not $script:TiaSession.Portal) {
        Connect-TiaPortal | Out-Null
        Step "attached to running Portal"
    }

    # 2) Project
    if ($Spec.project) {
        $pname = $Spec.project.name; $ppath = ResolvePath $Spec.project.path
        $apFile = Get-ChildItem $ppath -Filter "$pname.ap*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($apFile -and $Spec.project.openIfExists) {
            Open-TiaProject -ProjectFile $apFile.FullName | Out-Null; Step "opened project $pname"
        } else {
            if (Test-Path (Join-Path $ppath $pname)) { Remove-Item (Join-Path $ppath $pname) -Recurse -Force }
            New-TiaProject -Name $pname -Path $ppath | Out-Null; Step "created project $pname"
        }
    }

    # 3) PLCs
    foreach ($plcSpec in @($Spec.plcs)) {
        if (-not $plcSpec) { continue }
        try {
            $existing = Get-TiaPlc -Name $plcSpec.name | Select-Object -First 1
            if (-not $existing -and $plcSpec.orderNumber) {
                New-TiaDevice -TypeIdentifier $plcSpec.orderNumber -Name $plcSpec.name | Out-Null
                Step "added CPU $($plcSpec.name) ($($plcSpec.orderNumber))"
            }
            $sw = (Get-TiaPlc -Name $plcSpec.name | Select-Object -First 1).PlcSoftware
            if (-not $sw) { $sw = (Get-TiaPlc | Select-Object -First 1).PlcSoftware }
            if (-not $sw) { Fail "no PLC for spec '$($plcSpec.name)'"; continue }

            foreach ($tt in @($plcSpec.tagTables)) {
                if (-not $tt) { continue }
                foreach ($tag in @($tt.tags)) {
                    New-TiaTag -Plc $sw -TagTable $tt.name -Name $tag.name -DataType $tag.dataType -Address $tag.address -Comment $tag.comment | Out-Null
                }
                Step "tags: $($tt.name) (+$(@($tt.tags).Count))"
            }
            foreach ($t in @($plcSpec.types)) {
                if (-not $t) { continue }
                if ($t.sclFile) { New-TiaType -Plc $sw -Path (ResolvePath $t.sclFile) | Out-Null } else { New-TiaType -Plc $sw -Scl $t.scl | Out-Null }
                Step "UDT imported"
            }
            foreach ($b in @($plcSpec.blocks)) {
                if (-not $b) { continue }
                if ($b.sclFile) { Import-TiaScl -Plc $sw -Path (ResolvePath $b.sclFile) | Out-Null } else { Import-TiaScl -Plc $sw -Scl $b.scl | Out-Null }
                Step "block imported"
            }
            foreach ($db in @($plcSpec.dataBlocks)) {
                if (-not $db) { continue }
                if ($db.ofType) { New-TiaDataBlock -Plc $sw -Name $db.name -OfType $db.ofType | Out-Null } else { New-TiaDataBlock -Plc $sw -Scl $db.scl | Out-Null }
                Step "DB $($db.name)"
            }
            if ($plcSpec.compile) {
                $c = Invoke-TiaCompile -Plc $sw
                Step "compiled $($plcSpec.name): State=$($c.State) Errors=$($c.Errors) Warnings=$($c.Warnings)"
                if ($c.Errors -gt 0) { $c.Messages | Where-Object { $_ -like 'Error*' } | ForEach-Object { Fail $_ } }
            }
        } catch { Fail "PLC '$($plcSpec.name)': $($_.Exception.Message)" }
    }

    # 4) HMIs (screen import is the supported authoring path)
    foreach ($hmiSpec in @($Spec.hmis)) {
        if (-not $hmiSpec) { continue }
        try {
            foreach ($scr in @($hmiSpec.screens)) {
                if ($scr.importXml) { Import-TiaScreen -Hmi $hmiSpec.name -Path (ResolvePath $scr.importXml) -Overwrite | Out-Null; Step "HMI screen imported" }
            }
        } catch { Fail "HMI '$($hmiSpec.name)': $($_.Exception.Message)" }
    }

    if ($Spec.save) { Save-TiaProject; Step "saved project" }

    [pscustomobject]@{
        Ok       = ($report.Errors.Count -eq 0)
        Steps    = @($report.Steps)
        Errors   = @($report.Errors)
    }
}
