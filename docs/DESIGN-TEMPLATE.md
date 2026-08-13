# Project Design Document - TEMPLATE

> Copy this file to your project repo as `docs/DESIGN.md` and fill it in. It is the
> **single entry point** that makes a project buildable from scratch: every design fact is
> either stated here or linked from here. The generators consume the linked artifacts; a
> human (and the safety reviewer) reads this document.
>
> Rule of thumb: **decisions live in this document; data lives in the linked artifacts.**
> If a fact is stated twice, one of the copies is wrong.

---

## 0. Identity

| | |
|---|---|
| System | `<name, e.g. SR PPS - Storage Ring Personnel Protection System>` |
| Safety classification | `<none / SIL-x / PL-x + which standard: IEC 61508/62061, ISO 13849>` |
| Repo | `<git URL, visibility>` (engine consumed as submodule at `engine/`) |
| TIA version / Openness | `<V19 classic / V21 modular>`; required options: `<STEP 7 Professional, STEP 7 Safety, ...>` |
| Status | `<seed / under review / validated>` - if safety-relevant, banner-link the SAFETY doc |
| Owner / reviewer | `<who signs off>` |

**Safety banner** (delete if not a safety system): this project is a generated engineering
seed; nothing is deployable until the functional-safety lifecycle in
[`SAFETY.md`](SAFETY.md) completes.

## 1. Source-of-truth map

Every design aspect, its **format**, its **file**, and who reads/writes it. These formats
are the platform standard - deviate only with a reason recorded in section 12.

| Aspect | Format | File(s) | Written by | Consumed by |
|---|---|---|---|---|
| Design decisions | Markdown | `docs/DESIGN.md` (this) | human | human, reviewer |
| Master I/O list | as received (xlsx/pdf) | `source/<asbuilt>` | customer | normalizer |
| Normalized I/O | CSV | `source/normalized/{modules,points}.csv` | normalizer script | seeders |
| Hardware / stations | CSV (Station,Slot,OrderNumber,Name,Type,Evaluation) | `data/<zone>.iodevice.csv` | seeder | HW builder |
| Device model / channel pairing | CSV | `data/<zone>.pairing.csv` | seeder | logic + tag generators, validator |
| Signal polarity (NC/NO) | CSV override, default NC | `source/polarity.csv` | **human, from drawings** | seeder -> IOMap generator |
| UDT library | Python model (authoring) + **SimaticML XML export (canonical)** | `source/model.py` -> `data/_udts.csv`; canonical: `logic/types/*.xml` | model.py / TIA export | DB builder; reviewer |
| PLC tags | CSV (TagTable,Name,DataType,Address,Comment) | `data/<zone>.tags.csv` | address resolver | tag loader |
| Data blocks | CSV members -> SCL synthesis | `data/<zone>.dbs.{blocks,members}.csv` | seeder | DB builder |
| Standard logic | SCL text | `logic/*.scl` | human/generator | `Import-TiaScl` |
| Graphical / F logic | SimaticML XML (FlgNet) | `logic/FB_*.xml` | generators | `Import-TiaBlockXml` |
| Certified-block networks | XML **templates from canonical TIA exports** | `logic/templates/*.xml` | human places once -> export | generator instantiates |
| Live addresses | CSV, read back from built HW | `data/_addrmap.csv` | HW builder | address resolver |
| Build orchestration | PowerShell 5.1 pipeline | `source/build_*.ps1` | human | operator/CI |
| Offline validation | Python | `source/validate.py` + `validate.ps1` | human | CI |

Format rationale (keep, it answers "why not X"):
- **CSV** for anything tabular and per-row generated (devices, tags, modules): diffable,
  spreadsheet-editable by non-programmers, trivially parsed in both Python and PowerShell.
- **SimaticML XML** for anything TIA owns structurally (UDTs, LAD/F-LAD): it round-trips
  losslessly (`Export-TiaBlock` / `Import-TiaBlockXml`) and is the only representation of
  graphical logic. Canonical exports (from a reviewed TIA project) outrank hand-authored XML.
- **SCL** for standard (non-F) logic a human should read/write: portable, diffable.
- **Markdown** for decisions; **YAML** (`project.yaml`) only for simple spec-driven projects
  using `Invoke-TiaBuildFromSpec` - complex/safety projects use an explicit ps1 pipeline.

## 2. Hardware

- **CPU**: `<model + MLFB + FW, e.g. CPU 1512SP F-1 PN, 6ES7 512-1SK01-0AB0/V2.9>`;
  local modules on the CPU rack: `<list or link data/<zone>.iodevice.csv>`.
- **Remote stations**: one row per station -> `<data/*.iodevice.csv per zone>`.
  IM type/MLFB, module set, slot plan.
- **Module MLFB + firmware map**: exact order numbers incl. `/Vx.y` (PlugNew requires the
  FW suffix; keep the known-good map in the build script's `$FW` table).
- **Addressing policy**: `%I/%Q` are **assigned by TIA and read back** (`data/_addrmap.csv`)
  - never computed by formula. Any hardware change re-runs the resolver and re-verifies tags.
- **F-parameters**: F-monitoring time, F-source/dest addresses, per-channel settings -
  `<state values or "TIA defaults, to be set + assessed in safety review">`.

## 3. Network

- Subnet(s) + IO system(s): `<names, e.g. one PROFINET IO system PN_xxx on the CPU>`.
- Assignment recipe (Openness): subnet FIRST (`CreateAndConnectToSubnet`), then
  `IoController.CreateIoSystem`, then per-IM `ConnectToSubnet` + `ConnectToIoSystem`
  (engine `docs/SAFETY-LAD-SPIKE.md`).
- IP plan / device names: `<table or link>`.

## 4. Data model (UDTs + DBs)

- **UDT library**: device-oriented - one UDT per physical device type, composing a reusable
  safe-input struct. List every UDT with a one-line purpose; canonical definition =
  `logic/types/*.xml` (TIA export). Authoring model: `source/model.py`.
- **DB layout**: `<e.g. one DB_<zone> per zone; one UDT-typed member per device; zone
  scalars Zone_Safe/Zone_Fault/Zone_Reset/...>`. State whether each DB is a **formal F-DB**
  (marked in the safety editor - Openness cannot create one with UDT members; see caveats).
- **State policy**: logic operates on **DB members, not FB statics**; FB statics are only
  for instruction/FB **instances** (multi-instance).

## 5. Tags & polarity

- **Tag naming grammar** (BNF-ish, with 3+ examples):
  `<e.g. <SysPrefix>_<Area>_<Device><Name>_<Component>[_<State>]_<Signal>>`.
- Tag tables: `<names, e.g. FTags_In / FTags_Out / Diag>`.
- **Polarity convention**: default NC (1 = OK, de-energize-to-trip); exceptions ONLY via
  `source/polarity.csv`, inverted in the IOMap layer; never inferred. Every device's NC/NO
  verified against drawings: `<status>`.

## 6. Software architecture

- **Block inventory + numbering plan** (collision-free ranges):

| Block | Lang | Number | Role |
|---|---|---|---|
| `<Main_Safety_RTG1>` | F_LAD/F_FBD | 1 | safety runtime main (TIA-generated) |
| `<FB_<zone>_IOMap>` | F_LAD | `<51x>` | F-tag -> DB member (+ NO inversion) |
| `<FB_<zone>_Safety>` | F_LAD | `<51x>` | evaluation layer |
| `<FB_<zone>_Certified>` | F_LAD | `<53x>` | certified F-app-block calls |
| ... | | | |

- **Layering**: `<e.g. F-tag -> IOMap -> DB -> Safety/Certified -> outputs>` and what each
  layer is allowed to touch.
- **Runtime wiring**: which OB/F-runtime group calls what, and which calls are the
  **one-time manual safety-editor step** (F-instance DBs).

## 7. Safety design (delete for non-safety projects)

- Standards + the project's SAFETY doc: `<link>`; review gates and who holds the safety
  password.
- **Certified F-application blocks** used, with versions available on the engineering PC:
  `<ESTOP1 V1.2, SFDOOR V1.1, EV1oo2DI V1.x, FDBACK, ACK_GL>` and what each covers
  (latch/reset, discrepancy, reintegration).
- Redundancy architecture: `<1oo2 per device, evaluated where; single-channel exceptions ->
  data/_review_single_channel.csv>`.
- Reset/acknowledge concept: `<supervised reset source, AckReq annunciation>`.
- Passivation/reintegration concept; startup inhibit; first-out annunciation.

## 8. Programming conventions

- Languages: `<F-LAD for all safety logic; SCL for standard logic; no STL>`.
- No FB statics for data (DB members only); instances as multi-instance statics.
- IEC check: `<on/off + why>`; memory layout `<Optimized>`; symbolic access only.
- Comments: every network titled; every DB member commented from the source description.
- ASCII-only sources (engine constraint - PS 5.1 codepage).

## 9. Naming conventions

Link the full grammar (`docs/NAMING.md`) and restate the two or three rules people break:
`<no spaces (use _); device ids from the source are authoritative; zone prefix everywhere>`.

## 10. Generation pipeline

```
<one fenced block: the exact commands from clean checkout to compiled project,
 e.g. seed -> gen logic -> build HW -> resolve addresses -> build logic -> validate>
```
- Regeneration policy: what is safe to re-run, what clobbers manual TIA work, and the
  **frozen-seed rule** for safety projects (regeneration invalidates the F-signature ->
  new review cycle).
- Round-trip policy: manual TIA edits flow back ONLY via `Export-TiaBlock` into
  `logic/exported/` (or `logic/types/`), then get folded into generators/templates.

## 11. Verification & CI

- Offline validator: what `source/validate.py` checks (device/DB cross-refs, tag counts,
  XML well-formedness, source cross-check) - runs in CI without TIA.
- Live gates: `Invoke-TiaCompile` must be 0 errors before any claim of success; safety
  compile + collective F-signature recorded at: `<where>`.

## 12. Caveats & platform limits (link, don't re-discover)

Keep the project-relevant subset, each with a link to engine `docs/SAFETY-LAD-SPIKE.md` /
`docs/openness-cheatsheet.md`:

- Windows PowerShell 5.1 only; Openness group membership + logoff/on.
- Openness cannot (V19): set F-DI sensor evaluation through an attribute (no such
  attribute exists; it is readable as a parameter signature and changeable by replacing the
  module with a `PlugCopy` of a configured one), import `T#..` Time
  literals as FlgNet LiteralConstants, export `FOB_RTG1`, export inconsistent blocks,
  export blocks without a STEP 7 Professional license seat (UDT export needs none),
  create *standalone* F-instance DBs (moot with multi-instance architecture).
- Openness can (proven, canonical recipes in `PPS_SR_LAB/logic/exported/`): regenerate a
  FULL F-program from SimaticML - UDTs, **formal F-DBs**, F-LAD incl. FB-to-FB
  multi-instance calls and **`Main_Safety_RTG1` overwrite**, certified instructions
  (`ESTOP1`/`SFDOOR`/`EV1oo2DI`) as versioned `<Part>`s with `<Instance>` as the FIRST
  child + their TemplateValue signature; plug ET200SP incl. CPU-local modules; assign
  PROFINET IO systems (subnet-first).
- `<project-specific gotchas: BA00/BA01 byte widths, module quirks, ...>`

## 13. Decision log / open questions

| Date | Decision / question | Status |
|---|---|---|
| `<date>` | `<e.g. adopt PPS_ tag prefix>` | `<decided/open>` |

---
*Template version: 1.0 (engine `docs/DESIGN-TEMPLATE.md`). Improve the template upstream
when a project outgrows it.*
