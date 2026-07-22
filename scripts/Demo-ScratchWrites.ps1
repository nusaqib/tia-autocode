# Demo-ScratchWrites.ps1
# End-to-end WRITE demo against a throwaway project (never your real project).
# Requires membership in the 'Siemens TIA Openness' group (see Enable-OpennessAccess.ps1).
#
#   powershell -ExecutionPolicy Bypass -File .\Demo-ScratchWrites.ps1
#
param(
    [string]$WorkDir = "$env:TEMP\TIA_API_Scratch",
    [string]$ProjectName = 'ScratchDemo',
    [switch]$Headless
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\src\TiaOpenness\TiaOpenness.psd1" -Force

# 1) Start our OWN headless/UI portal so we never touch a human's open session.
Write-Host "Starting a dedicated TIA Portal instance..." -ForegroundColor Cyan
Connect-TiaPortal -New -WithUserInterface:(-not $Headless) | Out-Null

# 2) Create a fresh project.
if (Test-Path "$WorkDir\$ProjectName") { Remove-Item "$WorkDir\$ProjectName" -Recurse -Force }
Write-Host "Creating project '$ProjectName' in $WorkDir ..." -ForegroundColor Cyan
$project = New-TiaProject -Name $ProjectName -Path $WorkDir

# NOTE: a brand-new project has no PLC device yet. Adding a CPU device is done via
# project.Devices.CreateWithItem("OrderNo/...", name, ...). To keep this demo robust
# across catalogs, we detect an existing PLC; if none, we print guidance.
$plc = Get-TiaPlc | Select-Object -First 1
if (-not $plc) {
    Write-Warning "No PLC device in the new project. Add a CPU first (see docs/adding-a-device.md),"
    Write-Warning "or point this demo at a project template that already contains a CPU."
    Write-Host "Portal + empty project created successfully; stopping before tag/block writes." -ForegroundColor Yellow
    Save-TiaProject
    return
}
$sw = $plc.PlcSoftware
Write-Host "Target PLC: $($plc.Name)" -ForegroundColor Green

# 3) Create tags.
Write-Host "Creating tag table + tags..." -ForegroundColor Cyan
New-TiaTag -Plc $sw -TagTable 'IO' -Name 'Start_PB'  -DataType 'Bool' -Address '%I0.0' | Out-Null
New-TiaTag -Plc $sw -TagTable 'IO' -Name 'Stop_PB'   -DataType 'Bool' -Address '%I0.1' | Out-Null
New-TiaTag -Plc $sw -TagTable 'IO' -Name 'Motor_Run' -DataType 'Bool' -Address '%Q0.0' | Out-Null
Get-TiaTag -Plc $sw -TagTable 'IO' | Format-Table Name, DataType, Address -AutoSize

# 4) Create a FUNCTION (FC) from SCL - a reusable scaling routine.
Write-Host "Importing SCL function 'Scale'..." -ForegroundColor Cyan
Import-TiaScl -Plc $sw -Scl @'
FUNCTION "Scale" : Real
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT
    raw    : Int;
    hi_eng : Real;
    lo_eng : Real;
END_VAR
BEGIN
    // linear scale a 0..27648 raw analog value to engineering units
    #Scale := #lo_eng + (INT_TO_REAL(#raw) / 27648.0) * (#hi_eng - #lo_eng);
END_FUNCTION
'@ | Out-Null

# 5) Create a FUNCTION_BLOCK (FB) from SCL - a motor starter with seal-in.
Write-Host "Importing SCL function block 'MotorStarter'..." -ForegroundColor Cyan
Import-TiaScl -Plc $sw -Scl @'
FUNCTION_BLOCK "MotorStarter"
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT
    Start : Bool;
    Stop  : Bool;
END_VAR
VAR_OUTPUT
    Running : Bool;
END_VAR
BEGIN
    IF #Start THEN
        #Running := TRUE;
    END_IF;
    IF #Stop THEN
        #Running := FALSE;
    END_IF;
END_FUNCTION_BLOCK
'@ | Out-Null

Write-Host "Blocks now in project:" -ForegroundColor Cyan
Get-TiaBlock -Plc $sw | Format-Table Name, Type, Number, Language -AutoSize

# 6) Compile the PLC and report.
Write-Host "Compiling..." -ForegroundColor Cyan
$compile = Invoke-TiaCompile -Plc $sw
"Compile State=$($compile.State)  Errors=$($compile.Errors)  Warnings=$($compile.Warnings)"
$compile.Messages | Select-Object -First 20 | ForEach-Object { "  $_" }

Save-TiaProject
Write-Host "Saved. Closing portal we started." -ForegroundColor Green
Disconnect-TiaPortal -Close
