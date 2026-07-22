# ProjectRepo.ps1 - scaffold a new private machine repo that consumes this engine
# as a git submodule (Phase 5). Copies the project-template/ skeleton and fills in the
# machine name. Offline; no git is run (the next-steps tell you the submodule commands).

# Captured at dot-source time (top-level $PSScriptRoot = the Public folder).
$script:TiaProjectTemplateDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-template'

function New-TiaProjectRepo {
    <#
    .SYNOPSIS
        Scaffolds a new private project repo from the engine's project-template.
    .DESCRIPTION
        Copies the project-template skeleton (manifest, data CSVs, logic, build/validate
        scripts, offline-validation CI workflow, .gitignore, README) into -Path and
        replaces the {{MachineName}} token with -Name. Does not run git; the returned
        NextSteps list the submodule commands. Purely offline.
    .PARAMETER Path
        Target directory for the new repo (created if missing).
    .PARAMETER Name
        Machine name (fills project.name, the folder story, README title).
    .PARAMETER Force
        Allow scaffolding into a non-empty directory (overwrites matching files).
    .EXAMPLE
        New-TiaProjectRepo -Path C:\work\Line5 -Name Line5
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force
    )
    $tpl = $script:TiaProjectTemplateDir
    if (-not (Test-Path $tpl)) { throw "Project template not found: $tpl" }
    if (Test-Path $Path) {
        if (-not $Force -and @(Get-ChildItem $Path -Force -ErrorAction SilentlyContinue).Count) {
            throw "Target '$Path' is not empty. Use -Force to scaffold into it anyway."
        }
    } elseif ($PSCmdlet.ShouldProcess($Path, 'create directory')) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($Path, "scaffold project repo '$Name'")) {
        # Copy every item (incl. dotfiles/dotdirs) preserving structure.
        Get-ChildItem -LiteralPath $tpl -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Path -Recurse -Force
        }

        # Token-replace {{MachineName}} in text files that contain it.
        $textExt = '.md','.yaml','.yml','.ps1','.csv','.scl','.gitignore'
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Where-Object {
            $textExt -contains $_.Extension -or $_.Name -eq '.gitignore'
        } | ForEach-Object {
            $c = Get-Content -LiteralPath $_.FullName -Raw
            if ($c -match '\{\{MachineName\}\}') {
                ($c -replace '\{\{MachineName\}\}', $Name) | Set-Content -LiteralPath $_.FullName -Encoding ASCII
            }
        }
    }

    $steps = @(
        "cd `"$Path`"",
        "git init",
        "git submodule add https://github.com/nusaqib/tia-autocode.git engine",
        "git submodule update --init --recursive",
        "powershell -ExecutionPolicy Bypass -File .\validate.ps1   # offline check",
        "powershell -ExecutionPolicy Bypass -File .\build.ps1      # needs TIA Portal"
    )
    Write-Host "Scaffolded '$Name' at $Path" -ForegroundColor Green
    Write-Host "Next steps:" -ForegroundColor Cyan
    $steps | ForEach-Object { Write-Host "  $_" }

    [pscustomobject]@{ Path = (Resolve-Path $Path).Path; Name = $Name; NextSteps = $steps }
}
