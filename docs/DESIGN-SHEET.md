# Design-sheet schema contract (v1)

The **design sheet IS the project generator's input.** It fully determines the TIA
project - project and CPU, network, modules, data model, tags, and safety logic - with no
per-project code and no hidden constants. A new project is a new sheet, not new scripts.

```
Google Sheet --Sync-TiaDesignSheet--> design/csv/*.csv  (COMMITTED = the build input)
                                             |
                                    Test-TiaDesignSheet (offline, CI)
                                             |
                                    Invoke-TiaBuildFromSheet
                                             |
                                    complete TIA project
```

| Tab | Produces |
|---|---|
| `10_Project` | the project, the CPU, safety settings, naming + numbering rules |
| `20_Zones` | PROFINET stations and the IO system |
| `21_Modules` | plugged modules (CPU-local and remote) |
| `22_Devices` | typed members of each zone F-DB |
| `23_Channels` | PLC tags at live addresses + the IOMap rungs (incl. polarity inversion) |
| `30_UDTs` | the UDT library |
| `32_Blocks` | block inventory, languages, numbers |
| `33_SafetyBlocks` | certified ESTOP1 / SFDOOR / EV1oo2DI networks |
| `34_Interlocks` | zone interlock logic and the safety-runtime wiring |

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
| `PlcName` / `CpuMLFB` / `CpuFW` | CPU device name, order number, firmware (`V2.9`) |
| `CpuLocalZone` | zone whose modules plug on the CPU's own rack (blank = all remote) |
| `SubnetName` / `IoSystemName` | PROFINET subnet and IO-system names |
| `SafetyRuntimeFB` | safety main FB the zone FBs are called from (`Main_Safety_RTG1`) |
| `TagTableIn` / `TagTableOut` | tag-table names for F inputs / outputs |
| `TagPattern` | tag-name grammar, e.g. `PPS_{Zone}_{DeviceRef}_{Component}_{Signal}` |
| `DbPattern` / `BlockPattern` | `DB_{Zone}` / `FB_{Zone}_{Layer}` |
| `InstancePattern` | certified-instruction instance name, e.g. `Inst_{DeviceRef}_{Component}_{Instruction}` |
| `BlockNumberBase` / `BlockNumberStep` | per-zone block numbering (zone *i* -> base + i*step) |
| `DefaultPolarity` | `NC` |
| `RequireVerified` | `Yes`/`No` - refuse to generate safety logic from unverified rows |

Placeholders in patterns: `{Zone} {DeviceRef} {Component} {Signal} {Layer} {Instruction}`.
Unknown keys are a warning, not an error, so the sheet can carry project notes.

### Design - plant and hardware

**`20_Zones`** - one row per zone/area.

`Zone, Name, Description, Station, StationLabel, IM_MLFB, IM_FW, IOSystem, Verified, Notes`

- `Zone` - short code, primary key (`BTA`, `MCR`, `FE01`).
- `Station` - TIA station name (`IOD_BTA`); `StationLabel` - the as-built rack label.
- `IM_MLFB`/`IM_FW` - head module; blank when the zone is the CPU's own rack.

**`21_Modules`** - one row per plugged module.

`Zone, Slot, Kind, MLFB, FW, ModuleName, InputBytes, F_DestAddr, F_MonitorTime, SensorEval, AsBuiltRail, DrawingRef, Verified, Comment`

- `Kind` enum: `IM`, `F-DI`, `F-DQ`, `F-RQ`, `DI`, `DQ`.
- `(Zone, Slot)` unique. `ModuleName` unique within a zone.
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

`DeviceID, Zone, DeviceRef, DeviceType, UDT, Description, Location, DrawingRef, InInterlock, SF_ID, Verified, Notes`

- `DeviceID` - stable primary key. `DeviceRef` - the name used in code/DB member.
- `DeviceType` enum (project-extensible): `SCB`, `EMO`, `KeySwitch`, `CSD`, `Gate`,
  `RadDetector`, `KeyCache`, `Chain`, `Light`, `RF`.
- `UDT` - the UDT that types this device's DB member; must exist in `30_UDTs`.
- `InInterlock` (`Yes`/`No`) - declares trip-path relevance; cross-checked against
  `34_Interlocks`.

**`23_Channels`** - one row per physical channel. **The heart of the schema.**

`ChannelID, DeviceID, Component, Signal, Paired, Polarity, Slot, Channel, Terminal, LegacyTagName, ModuleName, DrawingRef, Description, Verified`

- `Signal` enum: `ChA`, `ChB`, `Diag`.
- `Paired` (`Yes`/`No`) - `No` means genuinely single-channel (1oo1). Never inferred.
- `Polarity` enum: `NC` (1 = OK, de-energize to trip) or `NO` (1 = demand, inverted with a
  negated contact in the IOMap). **A wiring-drawing fact; never guessed and never
  defaulted** - a blank is a named validation error, because a wrong polarity inverts a
  trip. `10_Project.DefaultPolarity` documents the house convention; it does not fill cells.
- `Slot`/`Channel`/`Terminal` - the as-built wiring, which is the only wiring.
- `LegacyTagName` - the existing plant tag, carried for traceability. Generated tag names
  come from `10_Project.TagPattern`; this column is never used as a tag.
- `(Zone, Slot, Channel)` must be unique - no two signals on one channel.

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
| `32_Blocks` | `Block, Zone, Layer, Language, Number, Description` |
| `33_SafetyBlocks` | `RowID, DeviceID, Component, Instruction, Version, InstanceName, DISCTIME, TIME_DEL, ACK_NEC, OPEN_NEC, AckSource, QTarget, Verified, Notes` |
| `34_Interlocks` | `Zone, Target, DeviceID, Member, Include, Rationale, SF_ID` |
| `35_Outputs` | `OutputID, Zone, DeviceID, Signal, Slot, Channel, DrivenBy, FDBACK` |

- `30_UDTs.Datatype` - S7 primitive or a quoted UDT reference (`"UDT_SafeInput"`).
  `Order` fixes member order. Nested UDTs must be defined before use.
- `32_Blocks.Layer` enum: `IOMap`, `Safety`, `Certified`, `Runtime`.
  `Language` enum: `F_LAD`, `F_DB`, `LAD`, `SCL`. `Number` unique per PLC.
- `33_SafetyBlocks.Instruction` enum: `ESTOP1`, `SFDOOR`, `EV1oo2DI`, `FDBACK`, `ACK_GL`.
  Time values (`DISCTIME`, `TIME_DEL`) in IEC form (`T#500ms`). These are **safety
  parameters** - each needs an engineering justification, not a default.
- `34_Interlocks.Target` enum: `Interlocks_OK`, `Zone_Safe`. `Include` (`Yes`/`No`) with a
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
4. `23_Channels.DeviceID` -> `22_Devices.DeviceID`; `22_Devices.Zone` -> `20_Zones.Zone`;
   `23_Channels.ModuleName` -> `21_Modules.ModuleName` within the same zone.
5. `22_Devices.UDT` -> `30_UDTs.UDT`; nested UDT datatypes resolve.
6. `33_SafetyBlocks.DeviceID`+`Component` -> an existing `23_Channels` component group.
7. `34_Interlocks.DeviceID` -> `22_Devices.DeviceID`.

Safety:
8. `(Zone, DesignSlot, DesignChannel)` unique; design slot/channel exists in `21_Modules`
   and is a channel-bearing byte of that module kind.
9. Every safety input channel has a `Polarity`.
10. `Paired=Yes` requires exactly one `ChA` and one `ChB` for that device+component;
    `Paired=No` requires exactly one `ChA` and is reported as **1oo1 needing review**.
11. Every `22_Devices` row with `InInterlock=Yes` appears in `34_Interlocks` with
    `Include=Yes`; every `Include=No` row has a non-empty `Rationale`.
12. `Verified=No` rows are reported; with `-RequireVerified` they are errors.

Exit code is non-zero on any error. Warnings do not fail the build but are printed.

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
  "tabs": { "20_Zones": "0", "21_Modules": "123456", "...": "..." }
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
