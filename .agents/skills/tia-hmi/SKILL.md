---
name: tia-hmi
description: Program Siemens WinCC HMI (Comfort/Advanced/Unified) via TIA Openness — find HMI devices, enumerate screens, author Unified screens from objects (New-TiaScreen/New-TiaScreenItem/Set-TiaScreenItemTag) or round-trip Comfort screen XML. Use for HMI/WinCC/panel/screen/faceplate/HMI-tag tasks in TIA Portal. Assumes the tia-openness skill for connection basics.
---

# WinCC HMI automation via Openness

Companion to the `tia-openness` skill. Connection, session, and project handling are
the same (`Connect-TiaPortal`, `New-/Open-TiaProject`). This skill covers the HMI side.

## HMI Openness is flavor-specific — discover before scripting

WinCC **Comfort/Advanced** (panel `HmiTarget`) and WinCC **Unified** expose different
object models, and collection names shift across TIA versions. So this layer is
discovery-first: find the HMI software, then inspect its real members before assuming.

```powershell
Get-TiaHmi                     # lists HMI software with its .NET type
Show-TiaHmiApi -Hmi HMI_1      # reflection dump: ScreenFolder, TagFolder, Connections, ...
```

Always run `Show-TiaHmiApi` against the actual HMI first — it tells you exactly which
properties/collections exist on THIS install, so you script real members, not guesses.

**Read the `SoftwareType`, not the panel's marketing name.** A *Unified Comfort Panel*
(`6AV2 128-*`) is **not** a classic Comfort panel: it reports
`Siemens.Engineering.HmiUnified.HmiSoftware` and behaves nothing like
`Siemens.Engineering.Hmi.HmiTarget`. Getting this wrong sends you down the XML path on a
device that has no screen XML at all.

| | Classic Comfort/Advanced | **Unified** |
|---|---|---|
| Software type | `Hmi.HmiTarget` | `HmiUnified.HmiSoftware` |
| Screens live in | `sw.ScreenFolder.Screens` (+ nested `.Folders`) | `sw.Screens` (flat, **no `ScreenFolder`**) |
| Screen XML | `Export()` / `Import()` — the only authoring path | **none** — `HmiScreen` has only `Delete()` |
| Create a screen | no `Create` — import XML | `Screens.Create(name)` |
| Create an object | no — edit the XML | `ScreenItems.Create<T>(name)` |
| Create a tag | no `Create(name)` — XML/master copy | `Create(name)` works |

`Get-TiaScreen` handles both and reports which one you have in its `Flavor` column.

## Screens on Unified — build them from objects

Unified has the richer API: create the screen, create objects on it, set properties,
bind tags. **Verified live on V19** against a `6AV2 128-3QB06-0AXx` Unified Comfort Panel.

```powershell
New-TiaScreen -Name Overview -Width 1920 -Height 1080
New-TiaScreenItem -Screen Overview -Name Gate_BTA -Type Button `
                  -Left 40 -Top 40 -Width 160 -Height 60
Set-TiaScreenItemTag -Screen Overview -Item Gate_BTA -Property ProcessValue -Tag BTA_Gate_OK
```

`-Type` accepts the type name with or without the `Hmi` prefix (`Button`, `HmiIOField`,
`Rectangle`, `Label`, `Gauge`, `Bar`, `Slider`, `ToggleSwitch`, `Circle`, `Line`, ...);
an unknown name throws and lists the ones this install has. All three cmdlets are
**idempotent** — re-running applies the requested geometry to the existing object rather
than duplicating or silently skipping it, so a generator converges. Re-using a name for a
*different* widget type is an error, not a silent swap.

Two traps, both hit live:

- **`ScreenItems.Create` and `Dynamizations.Create` are GENERIC** (`Create<T>(string)`),
  and Windows PowerShell 5.1 has no syntax for calling generic methods. They must go
  through `MakeGenericMethod` — same constraint as `GetService<T>` in the core skill.
- **Unified mixes signed and unsigned int properties.** A screen item's `Left`/`Top` are
  `Int32` but `Width`/`Height` are `UInt32`, so passing a PowerShell `[int]` straight to
  `SetValue` throws *"Object of type 'System.Int32' cannot be converted to type
  'System.UInt32'"*. Convert to `PropertyType` first (`Set-HmiProperty` does).

## Screens on Comfort/Advanced — XML round-trip

Classic panels offer no "draw a screen" API, so the reliable workflow is:

```powershell
Get-TiaScreen -Hmi HMI_1                                   # enumerate screens
Export-TiaScreen -Hmi HMI_1 -Name Start -Path .\Start.xml  # learn the schema / back up
# edit the XML (add objects, bind tags, change layout) ...
Import-TiaScreen -Hmi HMI_1 -Path .\Start.xml -Overwrite   # apply
```

To create a new screen: export an existing one as a template, edit name + content,
import it. Commit the screen XML to git for versioning and diffing.

On a Unified HMI both cmdlets refuse with a message naming the flavor and pointing at
`New-TiaScreen`/`New-TiaScreenItem` — they do not null-ref on the missing `ScreenFolder`.

## Create an HMI panel (device)

`New-TiaHmiDevice` adds a WinCC panel from a catalog order number (same CreateWithItem
path as `New-TiaDevice`). Live-validated on V19 with a **KTP700 Comfort**:

```powershell
New-TiaHmiDevice -OrderNumber '6AV2 124-1GC01-0AX0/17.0.0.0' -Name HMI_1 `
                 -DeviceItemName 'KTP700 Comfort'
```

The `/17.0.0.0` segment is the panel *image version* and varies by install; the MLFB
alone is not enough. Other Comfort MLFBs (TP700 `0GC01`, TP1200 `0MC01`, ...) share the
shape. In a spec, declare it under the `hmis` section:

```yaml
hmis:
  - name: HMI_1
    orderNumber: "OrderNumber:6AV2 124-1GC01-0AX0/17.0.0.0"
    deviceItemName: "KTP700 Comfort"
```
`Invoke-TiaBuildFromSpec` creates the panel if a matching HMI is not already present.

## HMI tags & connections

Tags and connections live under HMI-flavor-specific collections (`TagFolder`,
`Connections` on a Comfort `HmiTarget`). The module wraps them **discovery-first** -
each cmdlet locates the real member on THIS install rather than hardcoding a path:

```powershell
Get-TiaHmiConnection -Hmi HMI_1                     # list connections to the PLC
Get-TiaHmiTag        -Hmi HMI_1                      # list HMI tags across tables
New-TiaHmiTag -Hmi HMI_1 -Name MotorSpeed -DataType Real `
              -Connection HMI_Connection_1 -PlcTag '"Motor1_DB".Speed' -TagTable Motors
New-TiaHmiTag -Hmi HMI_1 -Name LocalCount -DataType Int   # internal (no -Connection)
```

`New-TiaHmiTag` finds the tag collection, calls `Create(name)`, then sets whichever of
`DataTypeName`/`Connection`/`PlcTag`/`Comment`/`AcquisitionCycleName` exist on this
flavor.

> **Verified live (V19 Comfort):** a Comfort `TagComposition` exposes only
> `CreateFrom(MasterCopy)` - there is **no** `Create(name)` - and its tag `DataType` is
> a typed link, not a string. So on Comfort/Advanced, `New-TiaHmiTag` cannot create
> tags; author them via **tag-table XML import** (below) or master copies. The
> declarative build detects this and records the CSV rows as validated-but-deferred
> rather than failing. Keep the hmitags CSV as the human-readable record.

## Tag tables & alarms - XML round-trip too

For anything the flat CSV cannot express, use the schema-exact XML path (same pattern
as screens):

```powershell
Export-TiaHmiTagTable -Hmi HMI_1 -Name Motors  -Path .\Motors.xml -Overwrite
Import-TiaHmiTagTable -Hmi HMI_1 -Path .\Motors.xml -Overwrite
Export-TiaHmiAlarms   -Hmi HMI_1 -Kind Discrete -Path .\DiscreteAlarms.xml -Overwrite
Import-TiaHmiAlarms   -Hmi HMI_1 -Kind Discrete -Path .\DiscreteAlarms.xml -Overwrite
```

## In the declarative build

`Invoke-TiaBuildFromSpec` `hmis` section drives HMI tags (CSV), connections, tag-table
XML, alarms, and screens:

```yaml
hmis:
  - name: HMI_1
    tags:         [ data/HMI_1.hmitags.csv ]   # CSV -> New-TiaHmiTag
    tagTablesXml: [ hmi/tags/Motors.xml ]      # schema-exact (optional)
    alarms:       [ { kind: Discrete, importXml: hmi/DiscreteAlarms.xml } ]
    screens:      [ hmi/screens/Start.xml ]
```

`Test-TiaSpec` validates the `hmis` section offline: hmitags columns (Name + DataType
required), duplicate-name detection, Connection-without-PLCTag warning, and that every
referenced screen/alarm/tag-table XML exists.

> Live HMI is flavor-dependent and these wrappers are reflection-based; validate against
> a scratch HMI before running them on anything real. Offline `Test-TiaSpec` coverage is
> in `tests/fixtures/hmi-spec/`.

## Git: do not ignore `IM/HMI/`

When a TIA project folder is committed, `IM/HMI/` **looks** like disposable staging — on a
Unified panel it is mirrored `Context/` and `Saved/` trees of zips, RDF stores and fonts,
around 12 MB — but nothing proves it regenerates, and the failure mode is a clone that
opens with HMI content missing while `git status` reads clean. Track it by default.

Only `TMP/`, `Logs/`, `XRef/`, `UserFiles/` and `IM/SearchIndex/` are demonstrably
regenerated. Settle any other candidate with a clean-clone-and-open test, not by
inspecting the file names.

## Safety

- HMI panels drive real operator interfaces — validate screen XML against a scratch
  project before importing into anything live.
- Attaching to a human's running session is read-only; do authoring in your own
  instance or a scratch project (see the tia-openness skill's safety rules).
