---
name: tia-hmi
description: Program Siemens WinCC HMI (Comfort/Advanced/Unified) via TIA Openness — find HMI devices, enumerate screens, and round-trip screen XML (export/import) to author HMI content. Use for HMI/WinCC/panel/screen/faceplate/HMI-tag tasks in TIA Portal. Assumes the tia-openness skill for connection basics.
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

## Screens — the supported authoring path is XML round-trip

Openness does not offer a rich "draw a screen" API. The reliable workflow is:

```powershell
Get-TiaScreen -Hmi HMI_1                                   # enumerate screens
Export-TiaScreen -Hmi HMI_1 -Name Start -Path .\Start.xml  # learn the schema / back up
# edit the XML (add objects, bind tags, change layout) ...
Import-TiaScreen -Hmi HMI_1 -Path .\Start.xml -Overwrite   # apply
```

To create a new screen: export an existing one as a template, edit name + content,
import it. Commit the screen XML to git for versioning and diffing.

## HMI tags & connections

These live under HMI-flavor-specific collections (e.g. `TagFolder`, `Connections` on a
Comfort `HmiTarget`). Because names vary, reach them via the discovered object:

```powershell
$hmi = (Get-TiaHmi -Name HMI_1).HmiSoftware
$hmi.TagFolder.Tags          # confirm the member name first with Show-TiaHmiApi
```

If a stable, tested wrapper is needed, add `New-TiaHmiTag` / `Get-TiaHmiConnection`
to `src/TiaOpenness/Public/Hmi.ps1` using the exact members `Show-TiaHmiApi` reports,
then export them in `TiaOpenness.psd1`.

## In the declarative build

`Invoke-TiaBuildFromSpec` supports an `hmis` section that imports screen XML:

```json
"hmis": [{ "name": "HMI_1", "screens": [{ "importXml": "screens\\Start.xml" }] }]
```

## Safety

- HMI panels drive real operator interfaces — validate screen XML against a scratch
  project before importing into anything live.
- Attaching to a human's running session is read-only; do authoring in your own
  instance or a scratch project (see the tia-openness skill's safety rules).
