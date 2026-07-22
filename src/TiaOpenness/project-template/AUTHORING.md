# Authoring guide - what to specify, and in which file

A project is described as **data + code**, and the tia-autocode engine turns it into a
compiled TIA Portal project. This guide is the reference for **every file and field**:
what to put where. (Reverse of this: `Export-TiaToSpec` generates these files from an
existing project.)

## Project layout

```
my-machine/
  engine/                     git submodule -> tia-autocode (pinned)
  project.yaml                THE MANIFEST - ties everything together
  data/                       tabular data (CSV, or an .xlsx workbook)
    PLC_1.tags.csv
    PLC_1.udts.csv
    PLC_1.dbs.blocks.csv
    PLC_1.dbs.members.csv
    PLC_1.modules.csv
    HMI_1.hmitags.csv
  logic/                      SCL code - FB / FC / OB
    FB_Motor.scl
  hmi/                        HMI XML (screens / tag tables / alarms), round-tripped from TIA
  generated/                  build snapshots for diffing (gitignored)
  build.ps1 / validate.ps1
```

Golden rule: **every path in `project.yaml` is relative to `project.yaml`.** Data goes in
`data/`, code in `logic/`, HMI XML in `hmi/` - but only the manifest makes it real.

---

## 1. `project.yaml` - the manifest

This is the one file that references everything else. Annotated example:

```yaml
project:
  name: MyMachine                 # project + .apXX name (required)
  path: _out/MyMachine            # where to create it; relative to this file
  openIfExists: false             # true = open an existing .apXX instead of recreating

portal:
  new: true                       # start our own headless instance (recommended for writes)
  ui: false                       # true = show the TIA UI

plcs:
  - name: PLC_1                    # CPU/station name (required)
    orderNumber: "OrderNumber:6ES7 515-2FM02-0AB0/V2.9"   # CPU MLFB + firmware (required to create)
    modules:  [ data/PLC_1.modules.csv ]        # rack I/O (optional)
    udts:     [ data/PLC_1.udts.csv ]           # user data types (optional)
    logic:                                       # FB/FC/OB - files or engine templates
      - logic/FB_Motor.scl
      - { template: MotorStarter, params: { Name: FB_Conveyor } }
    dbs:
      blocks:  data/PLC_1.dbs.blocks.csv         # one row per DB
      members: data/PLC_1.dbs.members.csv        # members of Global DBs
    tags:     [ data/PLC_1.tags.csv ]           # PLC tags (optional)
    compile:  true                               # compile after generating

hmis:
  - name: HMI_1
    orderNumber: "OrderNumber:6AV2 124-1GC01-0AX0/17.0.0.0"   # panel MLFB + image version
    deviceItemName: "KTP700 Comfort"
    tags:    [ data/HMI_1.hmitags.csv ]         # HMI tags (see the HMI note below)
    screens: [ hmi/Start.xml ]                   # screen XML (export from TIA, edit, re-import)
    alarms:  [ { kind: Discrete, importXml: hmi/DiscreteAlarms.xml } ]

naming:                            # optional lint (warnings only) - see section 5
  tags:  { case: Pascal }
  udts:  { prefix: UDT_ }
  fbs:   { prefix: FB_ }
  dbs:   { suffix: _DB }

build:
  snapshotDir: generated           # export blocks here after build (for git diff)
  save: true                       # persist the project (else it opens unsaved for review)
```

| Section | Key | Meaning |
|---|---|---|
| `project` | `name` / `path` / `openIfExists` | project name; where to create; open vs recreate |
| `portal` | `new` / `ui` | start our own instance; show UI |
| `plcs[]` | `name` / `orderNumber` | CPU station name; catalog MLFB + firmware |
| `plcs[]` | `modules` / `udts` / `logic` / `dbs` / `tags` / `compile` | the data/code for this CPU |
| `hmis[]` | `name` / `orderNumber` / `deviceItemName` | panel + catalog MLFB + image version |
| `hmis[]` | `tags` / `tagTablesXml` / `alarms` / `screens` | HMI content |
| `naming` | per kind | naming-convention rules (advisory) |
| `build` | `snapshotDir` / `save` | snapshot dir; whether to persist |

> The manifest may be `.yaml`/`.yml` (bundled reader) or `.json`. Use **block style**
> (indented) - the bundled YAML reader does not parse inline `{ ... }` flow mappings for
> the top-level sections.

---

## 2. Data files (`data/*.csv`)

One kind of data per file. Column order does not matter; header names do. Required
columns are marked **req**.

### `*.tags.csv` - PLC tags
| Column | Req | Notes |
|---|---|---|
| `TagTable` | yes | tag table name (created if missing) |
| `Name` | yes | tag name |
| `DataType` | yes | `Bool`, `Int`, `Real`, `Word`, ... or a `"UDTName"` |
| `Address` | yes | explicit, e.g. `%I0.0`, `%MW20`, `%Q0.1`, `%DB1.DBX0.0` |
| `Comment` | no | |
| `Retain` | no | `TRUE`/`FALSE` |

### `*.udts.csv` - user data types (one row per member)
| Column | Req | Notes |
|---|---|---|
| `UDT` | yes | UDT name (repeats for each member) |
| `Member` | yes | member name |
| `DataType` | yes | primitive or another `"UDTName"` |
| `Array` | no | e.g. `0..9` (makes `Array[0..9] of DataType`) |
| `StartValue` | no | |
| `Comment` | no | |

### `*.dbs.blocks.csv` - data blocks (one row per DB)
| Column | Req | Notes |
|---|---|---|
| `DBName` | yes | |
| `Number` | no | blank = auto-number |
| `Kind` | yes | `Global` \| `InstanceOfFB` \| `TypedOfUDT` |
| `OfType` | when Instance/Typed | the FB name (InstanceOfFB) or UDT name (TypedOfUDT) |
| `Optimized` | no | `TRUE`/`FALSE` (default TRUE) |
| `Comment` | no | |

### `*.dbs.members.csv` - members of **Global** DBs (one row per member)
| Column | Req | Notes |
|---|---|---|
| `DBName` | yes | must match a `Global` DB in dbs.blocks |
| `Member` | yes | |
| `DataType` | yes | primitive or `"UDTName"` |
| `StartValue` | no | |
| `Retain` | no | `TRUE`/`FALSE` |
| `Comment` | no | |

### `*.modules.csv` - rack I/O / comms modules (one row per slot)
| Column | Req | Notes |
|---|---|---|
| `Slot` | yes | integer, unique |
| `OrderNumber` | yes | module MLFB, e.g. `6ES7 521-1BH00-0AB0/V2.1` (version suffix required) |
| `Name` | yes | device-item name |
| `Comment` | no | |

### `*.hmitags.csv` - HMI tags
| Column | Req | Notes |
|---|---|---|
| `Name` | yes | |
| `DataType` | yes | `Bool`, `Int`, `Real`, ... |
| `Connection` | no | HMI connection name; blank = internal (non-connected) tag |
| `PLCTag` | when Connection set | source PLC tag / DB member, e.g. `"Motor1_DB".Speed` |
| `Acquisition` | no | acquisition cycle name, e.g. `1 s` |
| `Comment` | no | |
| `TagTable` | no | target HMI tag table (created if missing) |

---

## 3. Logic (`logic/*.scl`) and templates

Write **FB / FC / OB** as SCL files and list them under a PLC's `logic:`. Example FB:

```scl
FUNCTION_BLOCK "FB_Motor"
{ S7_Optimized_Access := 'TRUE' }
VAR_INPUT
    Start : Bool;
    Stop : Bool;
END_VAR
VAR_OUTPUT
    Running : Bool;
END_VAR
BEGIN
    IF #Start THEN #Running := TRUE; END_IF;
    IF #Stop  THEN #Running := FALSE; END_IF;
END_FUNCTION_BLOCK
```

Instead of a file, a `logic` entry can instantiate a reusable **engine template**:

```yaml
logic:
  - { template: MotorStarter, params: { Name: FB_Conveyor, SpeedType: Real } }
```

List available templates and their parameters with `Get-TiaTemplate`; preview one with
`Expand-TiaTemplate -Name MotorStarter -Parameters @{ Name = 'FB_Conveyor' }`. Drop your
own `.tmpl` files in a folder and add `templateDir: <folder>` to the entry to use them.

> **Build order** (per PLC): device -> modules -> UDTs -> **logic** -> DBs -> tags ->
> compile. Logic precedes DBs so an `InstanceOfFB` DB can find its FB.

---

## 4. HMI

- **Panel**: set `orderNumber` (+ `deviceItemName`) on the `hmis[]` entry; the panel is
  created if absent.
- **Tags**: `data/*.hmitags.csv` (columns above). **On WinCC Comfort/Advanced the API
  cannot create HMI tags** (their DataType is a typed link, not a string) - the build
  records the CSV rows as validated-but-deferred and you apply them via **tag-table XML
  import**: `Export-TiaHmiTagTable` -> edit the XML -> `Import-TiaHmiTagTable`.
- **Screens / alarms / tag tables**: authored as **SimaticML XML** round-tripped from a
  real panel (`Export-TiaScreen` / `Export-TiaHmiAlarms` / `Export-TiaHmiTagTable`), then
  referenced under `screens:` / `alarms:` / `tagTablesXml:`.

---

## 5. Naming rules (optional lint)

Add a `naming:` section to have `Test-TiaSpec` flag off-convention names as **warnings**
(never build-blocking). One rule set per object kind: `tags`, `udts`, `dbs`, `fbs`,
`fcs`, `hmiTags`, `modules`. Each may set:

| Rule | Meaning |
|---|---|
| `pattern` | a regex the name must match (case-sensitive) |
| `prefix` / `suffix` | required start / end |
| `maxLength` | max characters |
| `case` | `Pascal` \| `camel` \| `UPPER` \| `lower` \| `snake` |

Run standalone with `Test-TiaNaming -Path .\project.yaml` (or `-Rules <file|hashtable>`).

---

## 6. Spreadsheets: CSV or XLSX

Anywhere a data ref takes a `.csv`, you can point at an Excel worksheet instead -
`data/PLC_1.xlsx#Tags` (path `#` sheet name; defaults to the first sheet). Reading is
dependency-free (no Excel needed), so it also works in CI.

---

## 7. Datatypes & addresses (quick reference)

- **Types**: `Bool, Byte, Word, DWord, Int, DInt, Real, LReal, Time, String, Char`, or a
  UDT as `"MyType"`.
- **Addresses**: `%I0.0` (input bit), `%Q0.1` (output bit), `%M10.0` (memory bit),
  `%MW20` (memory word), `%IW64` (analog in), `%DB1.DBX0.0` (data bit).

---

## 8. Validate, then build

```powershell
# offline - no TIA needed, runs in CI:
powershell -ExecutionPolicy Bypass -File .\validate.ps1

# on a Windows PC with TIA Portal + Openness:
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

`validate.ps1` runs `Test-TiaSpec` (files exist, required columns present, addresses
well-formed, names unique, UDT/FB references resolve, naming lint). Fix errors before
building. `build.ps1` validates then generates + compiles the project.

---

## 9. Create a NEW project from the template

Each machine gets its own private repo that consumes the engine as a git submodule.
Scaffold one from the engine's built-in template:

```powershell
Import-Module <engine>\src\TiaOpenness\TiaOpenness.psd1 -Force
New-TiaProjectRepo -Path C:\work\NewMachine -Name NewMachine
```

Then wire the engine and start validating:

```bash
cd C:/work/NewMachine
git init
git add -A && git commit -m "Scaffold from tia-autocode template"
git submodule add https://github.com/nusaqib/tia-autocode.git engine
git commit -am "Add engine submodule"
powershell -ExecutionPolicy Bypass -File .\validate.ps1
```

You get this same skeleton (manifest + starter `data/`/`logic/` + `build.ps1` /
`validate.ps1` + offline-validation CI + this guide). Edit the data/logic to describe
your machine. Full linking details (cloning, pinning/upgrading the engine, adopting an
existing project): the engine's `docs/PROJECT-REPO-GUIDE.md`.
