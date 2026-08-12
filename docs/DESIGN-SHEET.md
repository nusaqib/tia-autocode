# Design-sheet schema contract (v1)

The **design sheet IS the project generator's input.** It fully determines the TIA
project - project and CPU, network, modules, data model, tags, and safety logic - with no
per-project code and no hidden constants. A new project is a new sheet, not new scripts.

```
design workbook --Sync-TiaDesignSheet--> design/csv/*.csv  (COMMITTED = the build input)
                                                |
                                       Test-TiaDesignSheet (offline, CI)
                                                |
                                       Invoke-TiaSheetPipeline
                                                |
                                       complete TIA project
```

| Command | Does |
|---|---|
| `Sync-TiaDesignSheet -Path .\design` | expand the workbook tabs into `design/csv` |
| `Test-TiaDesignSheet -Path .\design\csv` | offline schema + safety-rule check |
| `Invoke-TiaSheetPipeline -Clean -Save` | delete the old project, run all seven phases |
| `Invoke-TiaSheetPipeline -From Data -Save` | resume at a phase after fixing the design |
| `Invoke-TiaBuildFromSheet -Phase Types` | run exactly one phase |
| `Clear-TiaSheetBuild` | delete the generated project, XML and reports |
| `Export-TiaDesignWorkbook` | rebuild the workbook from `design/csv` (exact inverse) |

`Invoke-TiaSheetPipeline` stops at the first failing phase. The phases are a chain - Tags
reads the address map Hardware wrote, Certified reads the F-DBs Data created - so carrying
on past a failure would build safety logic on a known-bad foundation. `-ContinueOnError`
exists to see how far a design gets, not to produce a program.

`Clear-TiaSheetBuild` refuses to delete anything outside the repo's `_out` tree unless
forced: a typo in `ProjectPath` must not be able to erase a live project.

| Tab | Produces |
|---|---|
| `10_Project` | the project, the CPU, safety settings, naming + numbering rules |
| `20_Stations` | PROFINET stations, addressing and the IO system |
| `21_Modules` | plugged modules (CPU-local and remote) |
| `22_Devices` | typed members of each area F-DB |
| `23_Channels` | PLC tags at live addresses + the IOMap rungs (incl. signal inversion) |
| `30_UDTs` | the UDT library |
| `32_Blocks` | block inventory, languages, numbers |
| `33_SafetyBlocks` | certified ESTOP1 / SFDOOR / EV1oo2DI networks |
| `34_Interlocks` | area interlock logic and the safety-runtime wiring |

**`Area` is the key in every tab.** One short code (`MCR`, `BTA`, `S01_FE`) identifies a
station in `20_Stations` and is the foreign key from every other tab. It is also the
`{Area}` naming placeholder, so an area owns one station, one F-DB, and one block per
layer. (Before v1.3 this column was called `Zone`, which collided with the
radiation-safety meaning of "zone" in the drawings.)

**Why a committed snapshot and not a live read:** a build must be reproducible from a git
checkout alone; `git diff design/csv/` is the change record for every safety edit; and a
frozen-seed / F-signature policy needs an immutable record of *what was built*. The
network fetch is an explicit, on-demand sync step - never a build-time dependency, so CI
stays offline.

## Conventions

- One CSV per tab, named exactly as the tab: `design/csv/<TabName>.csv`.
- **Header casing is significant** (consumers do case-sensitive property access).
- IDs are stable and never reused; renaming a device changes `DeviceRef`, not `DeviceID`.
- Enum columns are closed sets (below). Blank is not a member of any enum.
- `Verified` (`Yes`/`No`) + `DrawingRef` appear on every row that feeds safety logic.
  **Generators refuse to emit certified safety logic from `Verified=No` rows** unless
  explicitly overridden - seeded/heuristic data can never silently become a trip path.
- **Derived values must not appear in the sheet**: `%I`/`%Q` addresses (read back from the
  built hardware), generated tag names, DB member paths, UDT library contents when it is a
  code constant. Anything stated twice will eventually disagree.
- Numeric slot/channel columns are integers, not Excel floats (`1`, not `1.0`).

## Tabs

Numbering leaves gaps so lifecycle tabs (`10_Requirements`, `11_SafetyFunctions`,
`40_TestCases`, `41_TestResults`) can be added without restructuring.

### Governance

| Tab | Columns |
|---|---|
| `00_README` | free text: purpose, schema version, sync instructions, enum legend |
| `01_Revisions` | `Rev, Date, Author, Summary, Approver, SnapshotCommit` |
| `02_Decisions` | `DecID, Topic, Question, Decision, Rationale, Status, Owner, Date` |

`02_Decisions.Status` enum: `Open`, `Decided`, `Superseded`.

### Project definition

**`10_Project`** - key/value, the parameters needed to create the project from nothing.

`Key, Value, Notes`

| Key | Meaning |
|---|---|
| `SchemaVersion` | must match the engine's supported version |
| `ProjectName` / `ProjectPath` | TIA project name and output folder (relative to repo) |
| `ProjectDescription` | free-text description of the system |
| `PlcName` / `CpuMLFB` / `CpuFW` | CPU device name, order number, firmware (`V2.9`) |
| `CpuLocalArea` | area whose modules plug on the CPU's own rack (blank = all remote) |
| `SubnetName` / `IoSystemName` | PROFINET subnet and IO-system names |
| `SafetyRuntimeFB` | safety main FB the area FBs are called from (`Main_Safety_RTG1`) |
| `TagTableIn` / `TagTableOut` | tag-table names for F inputs / outputs |
| `TagPattern` | tag-name grammar, e.g. `PPS_{Area}_{DeviceRef}_{Component}_{Signal}` |
| `DbPattern` / `BlockPattern` | `DB_{Area}` / `FB_{Area}_{Layer}` |
| `ModulePattern` | module-name grammar, e.g. `{Area}_{Kind}_{Slot}` -> `BTA_FDI_3` |
| `InstancePattern` | certified-instruction instance name, e.g. `Inst_{DeviceRef}_{Component}_{Instruction}` |
| `BlockNumberBase` / `BlockNumberStep` | per-area block numbering (area *i* -> base + i*step) |
| `SignalSense` | `FailSafe` - documents the house convention (see `23_Channels.Invert`) |
| `RequireVerified` | `Yes`/`No` - refuse to generate safety logic from unverified rows |

Placeholders in patterns: `{Area} {DeviceRef} {Component} {Signal} {Layer} {Instruction}`,
plus `{Kind}` and `{Slot}` in `ModulePattern`. Unknown keys are a warning, not an error, so
the sheet can carry project notes.

### Design - plant and hardware

**`20_Stations`** - one row per ET200SP station on the PROFINET IO system.

`Area, Name, Description, Station_Name, Station_Label, IM_MLFB, IM_FW, IO_System, IP_Address, Subnet_Mask, Device_Number, Device_Name, Verified, Notes`

- `Area` - short code, primary key (`BTA`, `MCR`, `S01_FE`), and the `{Area}` placeholder.
- `Station_Name` - the station's name **in the TIA project tree** (`IOD_BTA`).
- `Station_Label` - the as-built rack designation, written to the device's `Comment` (the
  only writable label Openness exposes; it shows in device properties and the network view).
- `IM_MLFB`/`IM_FW` - head module; blank when the area is the CPU's own rack.
- `IP_Address`/`Subnet_Mask` - pinned PROFINET addressing. **Blank means "let TIA assign"**;
  a value is applied to the interface node.
- `Device_Number` - PROFINET device number, unique on the IO system.
- `Device_Name` - PROFINET **device name**, assigned to the physical hardware over the wire
  (DCP) at commissioning. This is not `Station_Name`: the controller finds a station by this
  name and hands it its IP, so a mismatch means the station never comes online. Setting it
  switches auto-generation off first, or TIA regenerates it from the station name. Follow
  DNS rules - lower case, hyphens, no underscores (`iod-bta`).
- `IP_Address`, `Device_Number` and `Station_Name` must each be unique across the tab; a
  duplicate is a network fault the compiler will not catch.
- `Subnet_Mask` must be a real mask (contiguous 1-bits) and every station on one
  `IO_System` must share it. `255.255.255.1` is a well-formed dotted quad, a nonsense mask,
  and precisely what dragging an Excel fill handle down the column produces.

> Named `20_Stations`, **not** a "Devices" tab: `22_Devices` already means field devices
> (crash-off buttons, gates, detectors). Two tabs both called Device would give `DeviceID`
> and `DeviceRef` two different meanings in a safety review.

**`21_Modules`** - one row per plugged module.

`Area, Slot, Kind, MLFB, FW, ModuleName, InputBytes, F_DestAddr, F_MonitorTime, SensorEval, AsBuiltRail, DrawingRef, Verified, Comment`

- `Kind` enum: `IM`, `F-DI`, `F-DQ`, `F-RQ`, `DI`, `DQ`.
- `(Area, Slot)` unique. `ModuleName` unique within an area - `23_Channels` joins on
  `Area`+`ModuleName`, so a duplicate silently merges two racks' channels onto one module.
- `ModuleName` stays authored data (it is a foreign key), but it should follow
  `10_Project.ModulePattern`; drift is reported as a warning, not rewritten.
- `InputBytes` - process-image width (F-DI 8ch HF = 7). Used to sanity-check addresses;
  only **byte 0** of an F-DI range carries the 8 safe channel values.
- `F_DestAddr` - PROFIsafe destination address (F-destination). **Must be unique across
  the network** and is a reviewable safety parameter, so it is declared, not auto-assigned.
- `F_MonitorTime` - PROFIsafe monitoring time.
- `SensorEval` enum `1oo1`/`1oo2` - required on `F-DI`, rejected on non-F modules. Openness
  **cannot** set the F-DI sensor evaluation, so this column states the intended value: it
  drives the manual TIA step and lets a report check what was actually configured. With
  1oo2 evaluated in software (`EV1oo2DI`) this is normally `1oo1`.

**`22_Devices`** - one row per physical device.

`DeviceID, Area, DeviceRef, DeviceType, UDT, Description, Location, DrawingRef, InInterlock, SF_ID, Verified, Notes`

- `DeviceID` - stable primary key. `DeviceRef` - the name used in code/DB member.
- `DeviceType` enum (project-extensible): `SCB`, `EMO`, `KeySwitch`, `CSD`, `Gate`,
  `RadDetector`, `KeyCache`, `Chain`, `Light`, `RF`.
- `UDT` - the UDT that types this device's DB member; must exist in `30_UDTs`.
- `InInterlock` (`Yes`/`No`) - declares trip-path relevance; cross-checked against
  `34_Interlocks`.

**`23_Channels`** - one row per physical channel. **The heart of the schema.**

`ChannelID, DeviceID, Component, Signal, Paired, Invert, Slot, Channel, Terminal, LegacyTagName, ModuleName, DrawingRef, Description, Verified`

- `Signal` enum: `ChA`, `ChB`, `Diag`.
- `Paired` (`Yes`/`No`) - `No` means genuinely single-channel (1oo1). Never inferred.
- `Invert` enum: `Yes`/`No`, blank = `No`. **Signal sense.** The house convention is
  fail-safe: at the PLC input `1 = OK`, `0 = fault/demand`, so a channel maps straight
  through and everything downstream reads "1 = safe". `Invert=Yes` marks a device wired
  against that convention, and the IOMap emits a **negated contact** for it.
- `Slot`/`Channel`/`Terminal` - the as-built wiring, which is the only wiring.
- `LegacyTagName` - the existing plant tag, carried for traceability. Generated tag names
  come from `10_Project.TagPattern`; this column is never used as a tag.
- `(Area, Slot, Channel)` must be unique - no two signals on one channel.

> **`Invert` replaced `Polarity` (`NC`/`NO`) in v1.3.** `Polarity` restated the same fact
> on every one of 184 rows and left a blank meaning "unknown", which forced a hard error and
> a `-AssumeDefaultPolarity` escape hatch. Declaring the convention once in `10_Project` and
> listing only the exceptions makes the exceptions **visible** - three inverted channels are
> reviewable, 181 identical `NC` cells are not.
>
> The risk moves rather than disappearing: a blank now *asserts* fail-safe wiring, and
> nothing in the data can tell a correct blank from an unchecked one. The gate that bites is
> therefore **`Verified` on `23_Channels`**, and the IOMap phase prints every inverted
> channel by name and stamps the build `Provisional` while any channel is unverified.

> **Removed in v1.1: `DesignSlot`/`DesignChannel`.** They expressed the in-module re-map
> that *firmware* 1oo2 requires (ChA/ChB on channel *n* and *n+4* of one module). When 1oo2
> is evaluated in software the as-built wiring stands, and ChA/ChB on **separate modules**
> is the better arrangement - a single module failure cannot take both channels of a pair.
> Keeping a second set of wiring columns after that decision would only create ambiguity
> about which wiring is real.

### Design - software

| Tab | Columns |
|---|---|
| `30_UDTs` | `UDT, Order, Member, Datatype, Comment, FailsafeCompliant` |
| `32_Blocks` | `Block, Area, Layer, Language, Number, Description` |
| `33_SafetyBlocks` | `RowID, DeviceID, Component, Instruction, Version, InstanceName, DISCTIME, TIME_DEL, ACK_NEC, OPEN_NEC, AckSource, QTarget, Verified, Notes` |
| `34_Interlocks` | `Area, Target, DeviceID, Member, Include, Rationale, SF_ID` |
| `35_Outputs` | `OutputID, Area, DeviceID, Signal, Slot, Channel, DrivenBy, FDBACK` |

- `30_UDTs.Datatype` - S7 primitive or a quoted UDT reference (`"UDT_SafeInput"`).
  `Order` fixes member order. Nested UDTs must be defined before use.
- `32_Blocks.Layer` enum: `IOMap`, `Safety`, `Certified`, `Runtime`.
  `Language` enum: `F_LAD`, `F_DB`, `LAD`, `SCL`. `Number` unique per PLC.
- `33_SafetyBlocks.Instruction` enum: `ESTOP1`, `SFDOOR`, `EV1oo2DI`, `FDBACK`, `ACK_GL`.
  Time values (`DISCTIME`, `TIME_DEL`) in IEC form (`T#500ms`). These are **safety
  parameters** - each needs an engineering justification, not a default.
- `34_Interlocks.Target` enum: `Interlocks_OK`, `Area_Safe`. `Include` (`Yes`/`No`) with a
  `Rationale` - an excluded device must say why. This table makes **trip-path coverage
  auditable**: a device wired and indicated but absent from the interlock is worse than
  absent, because it looks functional.

### Generated reports (never authored here)

`Sync`/build emit `reports/90_AddressMap.csv`, `91_TagList.csv`, `92_Coverage.csv`. They
may be imported into the sheet as **read-only** tabs for review, but the repo copy is
authoritative.

## Validation rules (`Test-TiaDesignSheet`)

Structural:
1. Every required tab present; required columns present with exact casing.
2. Enum columns contain only members of their set.
3. Integer columns parse as integers.

Referential:
4. `23_Channels.DeviceID` -> `22_Devices.DeviceID`; `22_Devices.Area` -> `20_Stations.Area`;
   `23_Channels.ModuleName` -> `21_Modules.ModuleName` within the same area.
5. `22_Devices.UDT` -> `30_UDTs.UDT`; nested UDT datatypes resolve.
6. `33_SafetyBlocks.DeviceID`+`Component` -> an existing `23_Channels` component group.
7. `34_Interlocks.DeviceID` -> `22_Devices.DeviceID`.

Network:
8. `IP_Address` is a dotted IPv4 quad; `IP_Address`, `Device_Number` and `Station_Name`
   are each unique across `20_Stations`.
9. `Subnet_Mask` is a contiguous mask and is the same for every station on an `IO_System`.

Safety:
10. `(Area, Slot, Channel)` unique; the module exists in `21_Modules` for that area.
11. `Paired=Yes` requires exactly one `ChA` and one `ChB` for that device+component;
    `Paired=No` requires exactly one `ChA` and is reported as **1oo1 needing review**.
12. Every `22_Devices` row with `InInterlock=Yes` appears in `34_Interlocks` with
    `Include=Yes`; every `Include=No` row has a non-empty `Rationale`.
13. `Invert=Yes` channels are listed by name (each one negates a contact).
14. `Verified=No` rows are reported; with `-RequireVerified` they are errors. On
    `23_Channels` this is the gate for signal sense - see `Invert`.

Exit code is non-zero on any error. Warnings do not fail the build but are printed.

## Schema history

- **v1.3** - `Zone` -> **`Area`** in every tab (one name for one thing; "zone" meant
  something else in the drawings). `20_Stations` columns take underscore names and separate
  `Area` / `Station_Name` / `Station_Label`. `23_Channels.Polarity` -> **`Invert`** with the
  fail-safe convention declared once in `10_Project.SignalSense`. `10_Project` gains
  `ModulePattern`, loses `DefaultPolarity`, and `CpuLocalZone` becomes `CpuLocalArea`.
  DB members `Zone_Safe`/`Zone_Reset` become `Area_Safe`/`Area_Reset`.
- **v1.2** - `20_Zones` renamed `20_Stations` and given `IpAddress`, `SubnetMask`,
  `DeviceNumber`, `DeviceName`; `10_Project` gains `ProjectDescription`.
- **v1.1** - `23_Channels` lost `DesignSlot`/`DesignChannel` (one wiring truth);
  `21_Modules` gained the F-parameters; `31_Policy` added; `33_SafetyBlocks` became an
  override tab.
- **v1.0** - initial schema.

## Versioning

`00_README` carries `SchemaVersion`, mirrored in `design/sheet.json`.
`Test-TiaDesignSheet` fails when the snapshot's schema version is newer than the engine's
supported version. Adding an optional column is a minor bump; renaming/removing a column
or changing an enum is a major bump and requires a `01_Revisions` entry.

## Transport

`design/sheet.json`:

```json
{
  "schemaVersion": "1.0",
  "sheetId": "<google sheet id>",
  "transport": "published-csv",
  "tabs": { "20_Stations": "0", "21_Modules": "123456", "...": "..." }
}
```

- `transport: "published-csv"` - File > Share > Publish to web (per tab or whole doc).
  No credentials. **The sheet becomes readable by anyone with the URL** - confirm that is
  acceptable for the data before choosing it.
- `transport: "api-key"` / `"service-account"` - credentials live in the **private project
  repo** (gitignored, e.g. `design/*.key.json`), never in the engine.

`Sync-TiaDesignSheet` forces TLS 1.2, and fails loudly if a response is HTML rather than
CSV (an unpublished/permission-denied sheet returns a login page, which would otherwise be
written to disk as a "valid" CSV of garbage).
