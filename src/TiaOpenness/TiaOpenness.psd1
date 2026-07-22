@{
    RootModule        = 'TiaOpenness.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3f1e2a4-6c7d-4e8f-9a0b-1c2d3e4f5a6b'
    Author            = 'TIA_API platform'
    Description       = 'PowerShell driver for Siemens TIA Portal Openness: connect to a session and program tags, functions, blocks and routines.'
    PowerShellVersion = '5.1'
    # Openness is .NET Framework; require the FullCLR (Windows PowerShell), not PS Core.
    CompatiblePSEditions = @('Desktop')
    FunctionsToExport = @(
        'Get-TiaInstalledVersion','Get-TiaOpennessState',
        'Get-TiaSession','Connect-TiaPortal','Disconnect-TiaPortal',
        'New-TiaProject','Open-TiaProject','Get-TiaProject','Save-TiaProject','Close-TiaProject',
        'New-TiaDevice','Get-TiaPlc',
        'Get-TiaDeviceList','Get-TiaModule','Add-TiaModule',
        'Get-TiaTagTable','Get-TiaTag','New-TiaTagTable','New-TiaTag',
        'Get-TiaBlock','Import-TiaScl','Import-TiaBlockXml','Export-TiaBlock','Invoke-TiaCompile',
        'Get-TiaType','New-TiaType','New-TiaDataBlock',
        'New-TiaBlockGroup','Get-TiaBlockGroup','Remove-TiaBlock','New-TiaOb',
        'Get-TiaHmi','Show-TiaHmiApi','Get-TiaScreen','Export-TiaScreen','Import-TiaScreen',
        'Invoke-TiaBuildFromSpec',
        'Export-TiaProgram','Get-TiaOnlineState','Invoke-TiaDownload',
        'Test-TiaSpec'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{ PSData = @{ Tags = @('Siemens','TIA','Openness','PLC','Automation','SCL') } }
}
