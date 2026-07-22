# The tia-autocode framework

Three layers, lowest to highest:

1. **Connection & resolution** (`Private/`) — registry-driven Openness assembly
   loading (V19 classic / V21 modular), dependency resolver, session state.
2. **Cmdlet API** (`Public/`) — verb-noun commands over the Openness object model:
   sessions, projects, devices, tags, types, blocks, HMI, compile, export, download.
3. **Declarative generator** (`Build.ps1`) — `Invoke-TiaBuildFromSpec` materializes a
   whole program from a JSON spec. This is the "automatic coding" layer: describe the
   program as data, generate it reproducibly.

## Declarative spec

`Invoke-TiaBuildFromSpec -Path .\specs\demo.json` runs, in order:

```
portal (attach|new)
 └ project (create|open)
    └ for each PLC:
        device (add CPU by order number, if absent)
        tag tables + tags
        UDTs (SCL TYPE)
        code blocks (SCL FC/FB/OB, from text or .scl file)
        data blocks (SCL, or instance/typed "DB of <FB|UDT>")
        compile
 └ for each HMI:
        screens (XML import)
 └ save
```

Every section is optional. Unknown CPUs, know-how-protected blocks, and HMI-flavor
differences are caught per-item and surfaced in the returned `.Errors` — the build
continues rather than aborting. See [specs/demo.json](../specs/demo.json).

### Why SCL-first

Openness has no rich "create an FC and add networks" API in the classic model. The
robust, portable way to author logic is **text**: write SCL, register it as an
external source, and `GenerateBlocksFromSource()`. It round-trips cleanly, diffs well
in git, and is CPU-model-agnostic. For graphical (LAD/FBD) or exact-layout blocks,
drop to **SimaticML XML** (`Import-TiaBlockXml`) — learn the schema by exporting a
real block first.

## Version control workflow

`Export-TiaProgram -OutDir .\export\PLC_1 -IncludeTags` writes every block and tag
table to XML — a diffable snapshot you commit alongside the spec. Pattern:

```
specs/            <- declarative source of truth (hand-authored)
export/PLC_1/     <- generated XML snapshot (Export-TiaProgram, for diffing/backup)
```

Regenerate the project from `specs/`, or restore individual blocks via
`Import-TiaBlockXml`.

## Extending

Add a cmdlet by dropping a `Public/<Area>.ps1` with verb-noun functions; the loader
auto-discovers them. Add its name to `TiaOpenness.psd1` `FunctionsToExport`. Reuse
`Resolve-PlcSoftware` / `Resolve-HmiSoftware` for the `-Plc`/`-Hmi` parameter, and
`Get-Safe { }` for optional Openness properties inside hashtable literals.
