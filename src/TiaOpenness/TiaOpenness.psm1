# TiaOpenness.psm1 - module loader.
# Dot-sources Private (helpers) then Public (exported commands).

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($sub in 'Private','Public') {
    $dir = Join-Path $here $sub
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem -Path $dir -Filter '*.ps1' -Recurse | Sort-Object FullName | ForEach-Object {
        . $_.FullName
    }
}

# Export every adviced verb-noun function defined by the Public scripts.
$publicFns = Get-ChildItem (Join-Path $here 'Public') -Filter '*.ps1' -Recurse |
    ForEach-Object {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name }
    }
# A couple of diagnostics live in Private but are intentionally public.
$publicFns = @($publicFns) + @('Get-TiaInstalledVersion','Get-TiaOpennessState','Import-TiaXlsx')
Export-ModuleMember -Function ($publicFns | Select-Object -Unique)
