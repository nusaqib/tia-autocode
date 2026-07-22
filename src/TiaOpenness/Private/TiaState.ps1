# TiaState.ps1
# Holds the "current" TIA portal / project handles so interactive callers don't
# have to thread objects through every command. All public functions accept an
# explicit -Portal/-Project/-Plc too, so this is just an ergonomic default.

$script:TiaSession = [ordered]@{
    Portal   = $null   # Siemens.Engineering.TiaPortal
    Project  = $null   # Siemens.Engineering.Project
    StartedByUs = $false
}

function Get-Safe {
    # Evaluate a scriptblock, returning $null instead of throwing. Lets us read
    # optional Openness properties inline inside hashtable literals.
    param([scriptblock]$Script)
    try { & $Script } catch { $null }
}

function Get-CurrentPortal {
    param($Portal)
    if ($Portal) { return $Portal }
    if ($script:TiaSession.Portal) { return $script:TiaSession.Portal }
    throw "No TIA Portal connection. Run Connect-TiaPortal first (or pass -Portal)."
}

function Get-CurrentProject {
    param($Project)
    if ($Project) { return $Project }
    if ($script:TiaSession.Project) { return $script:TiaSession.Project }
    throw "No open TIA project. Run Open-TiaProject / New-TiaProject first (or pass -Project)."
}
