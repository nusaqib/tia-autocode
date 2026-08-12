# Design-sheet schema contract (v1)

The **design sheet** is a project's single source of truth for everything a generator
needs: hardware, devices, wiring, data model, and safety-block configuration. It is
authored in Google Sheets (or any spreadsheet), synced into the project repo as a
**committed CSV snapshot**, and validated offline before any build.

```
Google Sheet  --Sync-TiaDesignSheet-->  design/csv/*.csv  (COMMITTED = the build input)
                                              |
                                     Test-TiaDesignSheet  (offline, CI)
                                              |
                                        generators -> TIA
```

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

### Design - plant and hardware

**`20_Zones`** - one row per zone/area.

`Zone, Name, Description, Station, StationLabel, IM_MLFB, IM_FW, IOSystem, Verified, Notes`

- `Zone` - short code, primary key (`BTA`, `MCR`, `FE01`).
- `Station` - TIA station name (`IOD_BTA`); `StationLabel` - the as-built rack label.
- `IM_MLFB`/`IM_FW` - head module; blank when the zone is the CPU's own rack.

**`21_Modules`** - one row per plugged module.

`Zone, Slot, Kind, MLFB, FW, ModuleName, InputBytes, AsBuiltRail, DrawingRef, Verified, Comment`

- `Kind` enum: `IM`, `F-DI`, `F-DQ`, `F-RQ`, `DI`, `DQ`.
- `(Zone, Slot)` unique. `ModuleName` unique within a zone.
- `InputBytes` - process-image width (F-DI 8ch HF = 7). Used to sanity-check addresses;
  only **byte 0** of an F-DI range carries the 8 safe channel values.

**`22_Devices`** - one row per physical device.

`DeviceID, Zone, DeviceRef, DeviceType, UDT, Description, Location, DrawingRef, InInterlock, SF_ID, Verified, Notes`

- `DeviceID` - stable primary key. `DeviceRef` - the name used in code/DB member.
- `DeviceType` enum (project-extensible): `SCB`, `EMO`, `KeySwitch`, `CSD`, `Gate`,
  `RadDetector`, `KeyCache`, `Chain`, `Light`, `RF`.
- `UDT` - the UDT that types this device's DB member; must exist in `30_UDTs`.
- `InInterlock` (`Yes`/`No`) - declares trip-path relevance; cross-checked against
  `34_Interlocks`.

**`23_Channels`** - one row per physical channel. **The heart of the schema.**

`ChannelID, DeviceID, Component, Signal, Paired, Polarity, AsBuiltSlot, AsBuiltChannel, AsBuiltTerminal, AsBuiltTagName, DesignSlot, DesignChannel, ModuleName, DrawingRef, Description, Verified`

- `Signal` enum: `ChA`, `ChB`, `Diag`.
- `Paired` (`Yes`/`No`) - `No` means genuinely single-channel (1oo1). Never inferred.
- `Polarity` enum: `NC` (1 = OK, de-energize to trip - the default) or `NO` (1 = demand,
  inverted with a negated contact in the IOMap). **A wiring-drawing fact; never guessed.**
- **As-built vs Design columns are both required.** `AsBuilt*` records how the plant is
  wired today; `Design*` records the target assignment. When they differ (e.g. re-mapping
  both chains of a device onto one F-DI module for in-module 1oo2) that is a **wiring
  change requiring safety review** - it must be visible data, not a side effect of row
  order in a generator.
- `(Zone, DesignSlot, DesignChannel)` must be unique - no two signals on one channel.

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
