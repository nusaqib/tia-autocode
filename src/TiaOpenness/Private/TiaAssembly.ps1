# TiaAssembly.ps1
# Resolves and loads the Siemens TIA Openness API assemblies for a given version.
# The Openness DLLs live in the Portal install folder; their dependencies live in
# the Portal's Bin folder. We therefore register an AppDomain.AssemblyResolve
# handler that probes those folders before touching any Openness type.

$script:TiaOpennessState = [ordered]@{
    Loaded          = $false
    Version         = $null            # e.g. '19.0'
    EngineeringDll  = $null
    SearchDirs      = @()
    ResolveHandler  = $null
    Resolving       = (New-Object 'System.Collections.Generic.HashSet[string]')
}

function Get-TiaInstalledVersion {
    <#
    .SYNOPSIS
        Lists TIA Openness versions registered on this machine.
    .OUTPUTS
        PSCustomObject with Version, PortalVersion, EngineeringDll, PublicKeyToken.
    #>
    [CmdletBinding()]
    param()

    $root = 'HKLM:\SOFTWARE\Siemens\Automation\Openness'
    if (-not (Test-Path $root)) {
        throw "TIA Openness is not installed (registry key '$root' not found)."
    }

    foreach ($verKey in Get-ChildItem $root) {
        $ver = $verKey.PSChildName                                  # e.g. '19.0'
        $major = ($ver -split '\.')[0]
        # The per-assembly path map lives under PublicAPI\<AssemblyVersion>[\net48]
        $apiRoot = Join-Path $verKey.PSPath 'PublicAPI'
        if (-not (Test-Path $apiRoot)) { continue }

        # Prefer the assembly-version subkey matching this Portal major version.
        $verSubKey = Get-ChildItem $apiRoot |
            Where-Object { $_.PSChildName -like "$major.*" } |
            Select-Object -Last 1
        if (-not $verSubKey) { continue }

        # V21+ nests the values one deeper under a runtime-moniker subkey (net48).
        $valuesKey = $verSubKey
        $net = Get-ChildItem $verSubKey.PSPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match 'net' } | Select-Object -First 1
        if ($net) { $valuesKey = $net }

        $props = Get-ItemProperty $valuesKey.PSPath
        $engDll = $props.'Siemens.Engineering'          # classic (V19)
        $baseDll = $props.'Siemens.Engineering.Base'    # modular (V21)

        [pscustomobject]@{
            Version        = $ver
            Major          = [int]$major
            IsModular      = [bool]$baseDll
            EngineeringDll = if ($engDll) { $engDll } else { $baseDll }
            PublicKeyToken = $props.PublicKeyToken
            AssemblyVersion= $props.AssemblyVersion
        }
    }
}

function Resolve-TiaAssembly {
    <#
    .SYNOPSIS
        Loads the TIA Openness API for the requested (or newest available) version
        and wires up dependency resolution. Idempotent within a process.
    .PARAMETER Version
        Openness version like '19.0'. Defaults to the newest classic (non-modular)
        version installed, falling back to the newest of any kind.
    #>
    [CmdletBinding()]
    param([string]$Version)

    if ($script:TiaOpennessState.Loaded) {
        if ($Version -and $Version -ne $script:TiaOpennessState.Version) {
            throw "TIA Openness $($script:TiaOpennessState.Version) is already loaded in this process; cannot switch to $Version. Start a fresh PowerShell process."
        }
        return
    }

    $installed = @(Get-TiaInstalledVersion)
    if (-not $installed) { throw "No TIA Openness versions are registered on this machine." }

    if ($Version) {
        $target = $installed | Where-Object { $_.Version -eq $Version } | Select-Object -First 1
        if (-not $target) {
            throw "TIA Openness $Version is not installed. Available: $($installed.Version -join ', ')"
        }
    } else {
        # Prefer classic (best-supported) API first, then the highest version.
        $target = $installed |
            Sort-Object @{ Expression = 'IsModular'; Descending = $false },
                        @{ Expression = 'Major';     Descending = $true } |
            Select-Object -First 1
    }

    $engDll = $target.EngineeringDll
    if (-not (Test-Path $engDll)) {
        throw "Openness assembly not found on disk: $engDll"
    }

    # Build the dependency search path: the DLL's own folder, the Portal Bin folder,
    # and every folder referenced in the registry path map.
    $dllDir = Split-Path $engDll -Parent
    # PublicAPI\V19\Siemens.Engineering.dll -> Portal V19\Bin
    $portalRoot = (Get-Item $dllDir).Parent
    while ($portalRoot -and $portalRoot.Name -ne '' -and -not (Test-Path (Join-Path $portalRoot.FullName 'Bin'))) {
        $portalRoot = $portalRoot.Parent
    }
    $searchDirs = New-Object System.Collections.Generic.List[string]
    $searchDirs.Add($dllDir)
    if ($portalRoot) { $searchDirs.Add((Join-Path $portalRoot.FullName 'Bin')) }
    $searchDirs = $searchDirs | Where-Object { Test-Path $_ } | Select-Object -Unique

    # Dependency resolution uses a COMPILED C# handler rather than a PowerShell
    # scriptblock. Starting a full (headless) Portal or Attach() raises AssemblyResolve
    # for hundreds of dependencies across multiple threads; a scriptblock delegate
    # re-enters and StackOverflows the process. The C# handler has a [ThreadStatic]
    # re-entrancy guard and returns already-loaded assemblies, which is reliable.
    if (-not ('TiaOpenness.AssemblyResolver' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
namespace TiaOpenness {
    public static class AssemblyResolver {
        public static string[] SearchDirs = new string[0];
        [ThreadStatic] private static HashSet<string> _resolving;
        private static bool _registered;
        public static void Register() {
            if (_registered) return;
            AppDomain.CurrentDomain.AssemblyResolve += OnResolve;
            _registered = true;
        }
        private static Assembly OnResolve(object sender, ResolveEventArgs args) {
            string name = new AssemblyName(args.Name).Name;
            if (_resolving == null) _resolving = new HashSet<string>();
            if (_resolving.Contains(name)) return null;   // re-entrancy guard
            _resolving.Add(name);
            try {
                foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies()) {
                    try { if (a.GetName().Name == name) return a; } catch {}
                }
                foreach (string dir in SearchDirs) {
                    string p = Path.Combine(dir, name + ".dll");
                    if (File.Exists(p)) { try { return Assembly.LoadFrom(p); } catch {} }
                }
                return null;
            } finally { _resolving.Remove(name); }
        }
    }
}
'@
    }

    $script:TiaOpennessState.SearchDirs = @($searchDirs)
    [TiaOpenness.AssemblyResolver]::SearchDirs = [string[]]@($searchDirs)
    [TiaOpenness.AssemblyResolver]::Register()
    $script:TiaOpennessState.ResolveHandler = 'TiaOpenness.AssemblyResolver'

    # Load the entry assembly (+ companion assemblies for the modular API).
    [void][System.Reflection.Assembly]::LoadFrom($engDll)
    if ($target.IsModular) {
        foreach ($extra in 'Siemens.Engineering.Step7.dll','Siemens.Engineering.Hmi.dll') {
            $p = Join-Path $dllDir $extra
            if (Test-Path $p) { [void][System.Reflection.Assembly]::LoadFrom($p) }
        }
    }

    $script:TiaOpennessState.Loaded         = $true
    $script:TiaOpennessState.Version        = $target.Version
    $script:TiaOpennessState.EngineeringDll = $engDll

    Write-Verbose "Loaded TIA Openness $($target.Version) from $engDll"
}

function Get-TiaOpennessState {
    <#
    .SYNOPSIS
        Reports whether the Openness API is loaded, which version, and the resolver's
        assembly search directories.
    #>
    [CmdletBinding()] param()
    [pscustomobject]$script:TiaOpennessState
}
