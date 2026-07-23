# tia-autocode Roadmap — full project & HMI automation from specs

Goal: automate **complete** TIA Portal programming — tags, UDTs, data blocks, and
FB/FC/OB logic — plus HMI, driven by human-friendly specifications. Engineers author
tabular data (tags/UDTs/DBs/HMI-tags) in **Google Sheets** and logic as **SCL**; the
engine generates, compiles, and snapshots the project.

Status of decisions (locked 2026-07-21):
- Authoring surface: **Google Sheets**, read via **manual CSV export into the repo**
  (fully private; the engine needs no Google credentials).
- Engine consumed by project repos as a **git submodule** (pinned).
- Manifest: **YAML** (engine bundles YAML support; also accepts JSON).
- Addressing: **explicit only** (no auto-allocation).

---

## 1. Architecture: engine vs. project repos

| Layer | Repo | Contents | Visibility |
|---|---|---|---|
| **Engine** | `tia-autocode` (this repo) | module, spreadsheet readers, generator, validator, skills, docs | **Public** |
| **Project** | one per machine/customer | manifest + exported CSVs + SCL + HMI + build output | **Private** |

Private project-repo layout (scaffold it with `New-TiaProjectRepo -Path .\my-machine -Name MyMachine`):

```
my-machine/                          (private repo)
  engine/                            (git submodule -> tia-autocode, pinned commit)
  project.yaml                       (manifest)
  data/                              (CSV exported from Google Sheets - git-versioned)
    PLC_1.tags.csv
    PLC_1.udts.csv
    PLC_1.dbs.blocks.csv
    PLC_1.dbs.members.csv
    HMI_1.hmitags.csv
  logic/                             (SCL - the code)
    FC_Scale.scl
    FB_MotorStarter.scl
    OB_Main.scl
  hmi/screens/Start.xml
  generated/                         (build snapshots + logs, for git diff)
  build.ps1                          (imports engine, runs the build)
```

Why manual CSV export: keeps all customer data inside the private repo, gives git a
diffable record of exactly what was built, and avoids cloud credentials/secrets in the
engine. Google Sheets stays the friendly authoring/collaboration UI.

---

## 2. Authoring workflow

1. Author tags / UDTs / DBs / HMI-tags in a **Google Sheets** workbook (one workbook
   per PLC or HMI; one tab per data kind).
2. **Export**: in Sheets, `File -> Download -> Comma-separated values (.csv)` for each
   tab into `data/`. Commit — the CSVs are the versioned record.
3. Write FB/FC/OB as **SCL** in `logic/`.
4. Run `./build.ps1` -> validate -> generate -> compile -> snapshot -> report.

---

## 3. Specification formats

### 3.1 Manifest (`project.yaml`)

```yaml
project:
  name: MyMachine
  path: C:\work\MyMachine          # create here, or open an existing .apXX
portal:
  new: true                        # start our own instance (recommended for writes)
  ui: false
plcs:
  - name: PLC_1
    orderNumber: "OrderNumber:6ES7 515-2FM02-0AB0/V2.9"
    tags:    [ data/PLC_1.tags.csv ]
    udts:    [ data/PLC_1.udts.csv ]
    dbs:
      blocks:  data/PLC_1.dbs.blocks.csv
      members: data/PLC_1.dbs.members.csv
    logic:   [ logic/FC_Scale.scl, logic/FB_MotorStarter.scl, logic/OB_Main.scl ]
    compile: true
hmis:
  - name: HMI_1
    orderNumber:  "OrderNumber:6AV2 124-1GC01-0AX0/17.0.0.0"  # KTP700 Comfort (created if absent)
    deviceItemName: "KTP700 Comfort"
    tags:         [ data/HMI_1.hmitags.csv ]       # authored record; Comfort applies via XML import
    tagTablesXml: [ hmi/tags/Motors.xml ]          # schema-exact tag table (optional)
    alarms:       [ { kind: Discrete, importXml: hmi/DiscreteAlarms.xml } ]
    screens:      [ hmi/screens/Start.xml ]
build:
  order: [ udts, logic, dbs, tags, hmi ]   # logic before dbs (instance DBs need the FB)
  snapshotDir: generated
  save: false                              # leave unsaved for review (safe default)
```

### 3.2 CSV column contracts (canonical exported format)

> Phase 4: any tabular ref below may instead point at an Excel worksheet -
> `data/PLC_1.xlsx#Tags` - read dependency-free by `Import-TiaXlsx`. Same columns.

**tags** (`*.tags.csv`)
| Column | Req | Notes |
|---|---|---|
| TagTable | yes | created if missing |
| Name | yes | |
| DataType | yes | Bool, Int, Real, Word, "UDTName", ... |
| Address | yes | explicit, e.g. %I0.0, %MW20, %DB1.DBX0.0 |
| Comment | no | |
| Retain | no | TRUE/FALSE |

**udts** (`*.udts.csv`) — one row per member, grouped by UDT
| Column | Req | Notes |
|---|---|---|
| UDT | yes | UDT name (repeats per member) |
| Member | yes | member name |
| DataType | yes | primitive or "OtherUDT" |
| Array | no | e.g. 0..9 |
| StartValue | no | |
| Comment | no | |

**dbs.blocks** (`*.dbs.blocks.csv`) — one row per DB
| Column | Req | Notes |
|---|---|---|
| DBName | yes | |
| Number | no | blank = AutoNumber |
| Kind | yes | Global \| InstanceOfFB \| TypedOfUDT |
| OfType | when Instance/Typed | FB or UDT name |
| Optimized | no | TRUE/FALSE (default TRUE) |
| Comment | no | |

**dbs.members** (`*.dbs.members.csv`) — one row per member of a Global DB
| Column | Req | Notes |
|---|---|---|
| DBName | yes | |
| Member | yes | |
| DataType | yes | primitive or "UDTName" (e.g. the BTA/SE0101 : "SCB" pattern) |
| StartValue | no | |
| Retain | no | TRUE/FALSE |
| Comment | no | |

**hmitags** (`*.hmitags.csv`)
| Column | Req | Notes |
|---|---|---|
| Name | yes | |
| DataType | yes | Bool, Int, Real, ... |
| Connection | no | HMI connection name; blank = internal (non-connected) tag |
| PLCTag | when Connection set | source PLC tag / DB member (e.g. `"Motor1_DB".Speed`) |
| Acquisition | no | acquisition cycle name (e.g. `1 s`) |
| Comment | no | |
| TagTable | no | target HMI tag table (created if missing); default table otherwise |

HMI tags are created with `New-TiaHmiTag` (discovery-first: it locates the tag
collection for this WinCC flavor and sets the members that exist). Screens, HMI tag
tables, and alarms also round-trip as **SimaticML XML** via `Export/Import-TiaScreen`,
`Export/Import-TiaHmiTagTable`, and `Export/Import-TiaHmiAlarms` - the schema-exact path
for anything the flat CSV cannot express.

Logic (FB/FC/OB) stays as SCL files — code belongs in code, not spreadsheets.

---

## 4. Build pipeline

1. **Parse** manifest (YAML or JSON).
2. **Validate offline** (`Test-TiaSpec`, no TIA needed): files exist, required columns
   present, datatypes sane, UDT/type references resolve, no duplicate names, addresses
   well-formed, DB member types defined. Fail fast with a clear report.
3. **Connect** (new/attach) -> create/open project -> add device.
4. **Generate in order**: device -> modules -> UDTs -> SCL logic -> DBs -> tags -> HMI
   (logic precedes DBs so instance DBs resolve their FB). Rows are compiled
   to SCL (`TYPE...END_TYPE`, `DATA_BLOCK...END_DATA_BLOCK`) or API calls, reusing the
   validated cmdlets.
5. **Compile**; collect errors/warnings.
6. **Snapshot**: `Export-TiaProgram` to `generated/` (XML) for git diff.
7. **Report** steps + errors; leave the project unsaved unless `build.save: true`.

### Idempotency & safety
- **Add-or-update**: re-running updates existing objects; single-row edits (e.g. add
  one DB member) work via export/merge/import (generalizes the `BTA -> SE0201` case).
- **Safety (F) blocks**: detected and require the manual safety unlock in TIA. The
  engine never bypasses safety access protection.

---

## 5. Reverse / adoption (round-trip)

`Export-TiaToSpec` reads an existing project and emits CSVs + SCL, so you can adopt an
existing machine (e.g. `PPS_SR_`) into the spec model and diff future changes.

---

## 6. Phases

| Phase | Deliverable | Needs TIA? | Status |
|---|---|---|---|
| **0** | Manifest schema + CSV column contracts + `Test-TiaSpec` offline validator + example project skeleton + tests/CI | No | ✅ done |
| **1** | CSV readers + UDT/DB/tag/module synthesizers + manifest-driven `Invoke-TiaBuildFromSpec` + `generated/` snapshots | Yes | ✅ done (compiles 0/0 live) |
| **2** | `Export-TiaToSpec` (reverse adoption): tags/modules CSV + UDT/block XML + rebuildable manifest; `typesXml`/`blocksXml` round-trip import | Yes | ✅ done |
| **3** | HMI panel creation (`New-TiaHmiDevice` + `hmis[].orderNumber`) + tags (CSV) + connections + screen/tag-table/alarm XML round-trip, wired into the build + `Test-TiaSpec` | Yes | done - panel creation validated live (KTP700 Comfort); Comfort tag creation is API-limited (XML import), screen/tag/alarm XML wrappers offline-tested |
| **4** | Dependency-free XLSX import (`Import-TiaXlsx`; any csv ref may be `book.xlsx#Sheet`), naming-convention lint (`Test-TiaNaming`, folded into `Test-TiaSpec`), reusable UDT/SCL template library (`Get-/Expand-TiaTemplate`, `logic: { template, params }`) | Mixed | done (offline-tested; xlsx build + template build live-validated) |
| **5** | Private project-repo template + `New-TiaProjectRepo` scaffolder (submodule wiring, `build.ps1`/`validate.ps1`, offline-validation CI, starter data/logic) + docs | No | done (scaffold + generated-spec validation self-tested) |
| **6** | Safety/LAD generation + distributed ET200SP: emit LAD & F-LAD (FlgNet SimaticML), build ET200SP PROFINET stations with F-modules, PROFINET IO-system assignment, software 1oo2 | Yes | **proven at scale via SR PPS** ([SAFETY-LAD-SPIKE.md](SAFETY-LAD-SPIKE.md)): a whole system = 1 F-CPU + **16 ET200SP stations (76 modules) + 16 F-LAD safety FBs** built in one project, **compiles 0/0**. Openness boundaries documented (firmware 1oo2 not settable -> software 1oo2; F-block interfaces reject UDTs; safety-runtime call = TIA safety-editor step). Not yet folded into engine cmdlets - lives as the SR PPS project scripts. |

Phase 0 is fully offline and testable — it lands first and locks the contracts
everything else builds on.

---

## 7. Dependencies & constraints

- **CSV**: native `Import-Csv` (zero dependency).
- **YAML**: engine bundles a small YAML reader (or vendors `powershell-yaml`, MIT) and
  also accepts a `project.json` manifest as a dependency-free fallback.
- **Windows PowerShell 5.1**, **ASCII-only sources** (a self-test guards this).
- **Safety blocks** require the manual TIA safety unlock.

## 8. Security & privacy

- Customer data lives **only** in private project repos — never in the public engine.
- Google Sheets are exported manually into the private repo; the engine needs no Google
  credentials or network access.
- `generated/` snapshots can contain customer logic — private repos only.
