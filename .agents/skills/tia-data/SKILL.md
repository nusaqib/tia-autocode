---
name: tia-data
description: Create PLC data in TIA Portal via Openness - tags and tag tables (New-TiaTag/New-TiaTagTable), user data types/UDTs (New-TiaType), and data blocks incl. global, instance-of-FB, and typed-of-UDT (New-TiaDataBlock), plus adding members to an existing DB. Use for tag/tag-table/UDT/data-block/DB-member tasks, S7 datatypes/addresses, or generating data from a spreadsheet. Assumes the tia-openness skill for connection.
---

# TIA PLC data automation (tags, UDTs, DBs)

Companion to `tia-openness`. Covers the data model: tags, user data types, data blocks.

## Tags & tag tables

```powershell
New-TiaTag -Plc $plc -TagTable IO -Name Start_PB -DataType Bool -Address '%I0.0' -Comment 'start'
Get-TiaTag -Plc $plc -TagTable IO
```
- Addresses are explicit: `%I0.0`, `%Q0.1`, `%M10.0`, `%MW20`, `%MD100`, `%IW64`,
  `%DB1.DBX0.0`. `New-TiaTag` creates the tag table if missing.

## UDTs (user data types)

```powershell
New-TiaType -Plc $plc -Scl @'
TYPE "MotorData"
STRUCT
    Speed : Real := 0.0;
    Running : Bool;
    History : Array[0..9] of Real;
END_STRUCT;
END_TYPE
'@
```

## Data blocks - three kinds

```powershell
# Global DB with inline members
New-TiaDataBlock -Plc $plc -Scl @'
DATA_BLOCK "Settings"
{ S7_Optimized_Access := 'TRUE' }
VAR  Setpoint : Real := 50.0; Motor1 : "MotorData"; END_VAR
BEGIN
END_DATA_BLOCK
'@

# Instance DB of an FB
New-TiaDataBlock -Plc $plc -Name Motor1_DB -OfType MotorStarter
```

## Add a member to an EXISTING DB (export -> edit XML -> import)

Openness has no direct "add DB member" call. Export the DB to SimaticML, insert the
member into the `Static` section, re-import with override:

```powershell
Export-TiaBlock -Plc $plc -Name BTA -Path BTA.xml -Overwrite
# clone an existing <Member .../> node, rename it, keep the same Datatype (e.g. "SCB")
Import-TiaBlockXml -Plc $plc -Path BTA.xml -Overwrite
```
This is exactly how a new `SE0201 : "SCB"` sibling is added next to `SE0101`.

**Safety (F) DBs**: modifying an `F_DB` needs the safety program unlocked in TIA
(Safety Administration -> Access protection). Openness throws
"permission to modify the safety program is missing" otherwise. Never bypass it.

## From spreadsheets (Phase 1)

CSV contracts drive generation (see docs/ROADMAP.md and docs/SPECIFICATION.md):
- `*.udts.csv`: `UDT,Member,DataType,Array,StartValue,Comment`
- `*.dbs.blocks.csv`: `DBName,Number,Kind(Global|InstanceOfFB|TypedOfUDT),OfType,Optimized,Comment`
- `*.dbs.members.csv`: `DBName,Member,DataType,StartValue,Retain,Comment`
- `*.tags.csv`: `TagTable,Name,DataType,Address,Comment,Retain`

The engine synthesizes SCL from these and imports. Validate with `Test-TiaSpec` first
(checks datatypes are primitives or defined UDTs, addresses are well-formed, names unique).
After changes always `Invoke-TiaCompile` and check `.Errors`.
