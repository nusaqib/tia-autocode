---
name: tia-programming
description: Author PLC program logic in TIA Portal via Openness - Organization Blocks (OB), Function Blocks (FB), and Functions (FC) written in SCL and generated into the project (Import-TiaScl / New-TiaOb), plus SimaticML XML import/export for LAD/FBD/STL, block folders, and compile. Use for OB/FB/FC/SCL/LAD/FBD/STL/routine/logic/compile tasks. Assumes the tia-openness skill for connection.
---

# TIA program logic automation (OB / FB / FC)

Companion to `tia-openness`. Covers writing PLC logic blocks.

## SCL-first: the reliable way to author logic

`Import-TiaScl` writes the SCL to a temp external source and generates real blocks
from it. Portable, diffable, CPU-model-agnostic. One source can define several blocks.

```powershell
# Function (FC)
Import-TiaScl -Plc $plc -Scl @'
FUNCTION "Scale" : Real
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT raw : Int; hi_eng : Real; lo_eng : Real; END_VAR
BEGIN
    #Scale := #lo_eng + (INT_TO_REAL(#raw) / 27648.0) * (#hi_eng - #lo_eng);
END_FUNCTION
'@

# Function block (FB) with state
Import-TiaScl -Plc $plc -Scl @'
FUNCTION_BLOCK "MotorStarter"
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT Start : Bool; Stop : Bool; END_VAR
VAR_OUTPUT Running : Bool; END_VAR
BEGIN
    IF #Start THEN #Running := TRUE; END_IF;
    IF #Stop  THEN #Running := FALSE; END_IF;
END_FUNCTION_BLOCK
'@

# Organization block (OB) - cyclic Main calls the FB via its instance DB
New-TiaOb -Plc $plc -Scl @'
ORGANIZATION_BLOCK "Main"
BEGIN
    "Motor1_DB"(Start := "Start_PB", Stop := "Stop_PB");
    "Motor_Run" := "Motor1_DB".Running;
END_ORGANIZATION_BLOCK
'@
```

From files: `Import-TiaScl -Plc $plc -Path .\logic\FC_Scale.scl`.

## Graphical / exact-layout blocks: SimaticML XML

For LAD/FBD/STL, networks, and precise layout, use XML. Learn the schema by exporting
a real block, edit, re-import:

```powershell
Export-TiaBlock -Plc $plc -Name SomeBlock -Path b.xml -Overwrite
Import-TiaBlockXml -Plc $plc -Path b.xml -Overwrite
```

## Organize & compile

```powershell
New-TiaBlockGroup -Plc $plc -Path 'Motion/Axes'
Get-TiaBlock -Plc $plc -Type FC
$c = Invoke-TiaCompile -Plc $plc
"State=$($c.State) Errors=$($c.Errors) Warnings=$($c.Warnings)"; $c.Messages
```
Always confirm `Errors -eq 0` before claiming success.

## From the declarative build (Phase 1)

Logic stays as SCL files referenced by the manifest - code belongs in code, not
spreadsheets:

```yaml
plcs:
  - name: PLC_1
    logic: [ logic/FC_Scale.scl, logic/FB_MotorStarter.scl, logic/OB_Main.scl ]
    compile: true
```

`Test-TiaSpec` checks that referenced SCL files exist and that FB names referenced by
instance DBs (`InstanceOfFB`) are actually defined in the logic. Safety (F) blocks
require the TIA safety program to be unlocked before Openness can modify them.
