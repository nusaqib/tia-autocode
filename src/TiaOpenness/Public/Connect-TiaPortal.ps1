function Get-TiaSession {
    <#
    .SYNOPSIS
        Lists running TIA Portal instances that Openness can attach to.
    .DESCRIPTION
        Wraps Siemens.Engineering.TiaPortal.GetProcesses(). Each result exposes the
        process Id, the open project path, and the UI mode.
    .EXAMPLE
        Get-TiaSession
    #>
    [CmdletBinding()]
    param([string]$Version)

    Resolve-TiaAssembly -Version $Version
    $procs = [Siemens.Engineering.TiaPortal]::GetProcesses()
    foreach ($p in $procs) {
        [pscustomobject]@{
            Id          = $p.Id
            ProjectPath = if ($p.ProjectPath) { $p.ProjectPath.FullName } else { $null }
            Mode        = $p.Mode
            AttachTime  = $p.AcquisitionTime
            _Process    = $p        # keep raw handle for Connect-TiaPortal
        }
    }
}

function Connect-TiaPortal {
    <#
    .SYNOPSIS
        Attaches to a running TIA Portal, or starts a new instance.
    .DESCRIPTION
        With -Attach (default when a session exists) it attaches to a running
        Portal process. With -New it starts a fresh Portal. The resulting
        TiaPortal object becomes the module's current portal.
    .PARAMETER ProcessId
        Attach to a specific running Portal process Id (from Get-TiaSession).
    .PARAMETER New
        Start a brand-new Portal instance instead of attaching.
    .PARAMETER WithUserInterface
        When starting new, launch with the UI visible (default) vs headless.
    .EXAMPLE
        Connect-TiaPortal                     # attach to the only running session
    .EXAMPLE
        Connect-TiaPortal -New -WithUserInterface:$false   # headless engineering
    #>
    [CmdletBinding(DefaultParameterSetName = 'Attach')]
    param(
        [Parameter(ParameterSetName = 'Attach')] [int]$ProcessId,
        [Parameter(ParameterSetName = 'New')]    [switch]$New,
        [bool]$WithUserInterface = $true,
        [string]$Version
    )

    Resolve-TiaAssembly -Version $Version

    if ($New) {
        $mode = if ($WithUserInterface) {
            [Siemens.Engineering.TiaPortalMode]::WithUserInterface
        } else {
            [Siemens.Engineering.TiaPortalMode]::WithoutUserInterface
        }
        Write-Verbose "Starting new TIA Portal ($mode)..."
        $portal = New-Object Siemens.Engineering.TiaPortal($mode)
        $script:TiaSession.StartedByUs = $true
    }
    else {
        $procs = [Siemens.Engineering.TiaPortal]::GetProcesses()
        if (-not $procs -or $procs.Count -eq 0) {
            throw "No running TIA Portal found to attach to. Use -New to start one."
        }
        $proc = if ($ProcessId) {
            $procs | Where-Object { $_.Id -eq $ProcessId } | Select-Object -First 1
        } else {
            if ($procs.Count -gt 1) {
                Write-Warning "Multiple TIA sessions running; attaching to the first (Id=$($procs[0].Id)). Pass -ProcessId to choose."
            }
            $procs[0]
        }
        if (-not $proc) { throw "No TIA session with process Id $ProcessId." }
        Write-Verbose "Attaching to TIA Portal Id=$($proc.Id)..."
        $portal = $proc.Attach()
        $script:TiaSession.StartedByUs = $false
    }

    $script:TiaSession.Portal = $portal
    # If a project is already open in the attached session, adopt it as current.
    if ($portal.Projects.Count -gt 0) {
        $script:TiaSession.Project = $portal.Projects[0]
    }

    [pscustomobject]@{
        Version      = $script:TiaOpennessState.Version
        StartedByUs  = $script:TiaSession.StartedByUs
        OpenProjects = @($portal.Projects | ForEach-Object { $_.Name })
        Portal       = $portal
    }
}

function Disconnect-TiaPortal {
    <#
    .SYNOPSIS
        Detaches from (or closes) the current TIA Portal.
    .PARAMETER Close
        Also dispose the Portal. Only do this for instances you started (-New);
        never force-close a session a human is working in.
    #>
    [CmdletBinding()]
    param([switch]$Close)

    $portal = $script:TiaSession.Portal
    if (-not $portal) { Write-Verbose "No active connection."; return }

    if ($Close) {
        if (-not $script:TiaSession.StartedByUs) {
            Write-Warning "This session was not started by us; disposing anyway because -Close was given."
        }
        $portal.Dispose()
    }
    $script:TiaSession.Portal  = $null
    $script:TiaSession.Project = $null
    $script:TiaSession.StartedByUs = $false
}
