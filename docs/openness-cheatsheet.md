# TIA Openness cheat-sheet (V19 classic API)

Raw `Siemens.Engineering` idioms behind the `TiaOpenness` module. Use these when you
need something the module doesn't wrap.

## Load the API + resolve dependencies

```powershell
$dll = 'C:\Program Files\Siemens\Automation\Portal V19\PublicAPI\V19\Siemens.Engineering.dll'
$bin = 'C:\Program Files\Siemens\Automation\Portal V19\Bin'
[AppDomain]::CurrentDomain.add_AssemblyResolve([ResolveEventHandler]{
    param($s,$e)
    $n = ($e.Name -split ',')[0]
    foreach ($d in @($bin, (Split-Path $dll))) {
        $c = Join-Path $d "$n.dll"; if (Test-Path $c) { return [Reflection.Assembly]::LoadFrom($c) }
    }
    $null
})
[void][Reflection.Assembly]::LoadFrom($dll)
```

The module's `Resolve-TiaAssembly` does this from the registry automatically.

## Attach vs start

```powershell
$procs  = [Siemens.Engineering.TiaPortal]::GetProcesses()   # works without group membership
$portal = $procs[0].Attach()                                # needs 'Siemens TIA Openness' group
# or headless:
$portal = New-Object Siemens.Engineering.TiaPortal([Siemens.Engineering.TiaPortalMode]::WithoutUserInterface)
```

## Reach a CPU's software (the key cast)

The programmable surface lives on `PlcSoftware`, reached via a DeviceItem service:

```powershell
$svc = [Siemens.Engineering.HW.Features.SoftwareContainer]
$mi  = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($svc)
$container = $mi.Invoke($deviceItem, $null)     # null on items that aren't CPUs
$plcSoftware = $container.Software               # Siemens.Engineering.SW.PlcSoftware
```

`Get-TiaPlc` walks every device/device-item and returns the `PlcSoftware` for each CPU.

## Object model quick reference

| You want | Path from `PlcSoftware` (`$sw`) |
|----------|--------------------------------|
| Tag tables | `$sw.TagTableGroup.TagTables` (+ `.Groups` recurse) |
| A tag | `$table.Tags.Create(name, dataType, address)` |
| Blocks | `$sw.BlockGroup.Blocks` (+ `.Groups` recurse) |
| Block type | `$block.GetType().Name` → `OB`/`FB`/`FC`/`GlobalDB`/`InstanceDB` |
| External sources | `$sw.ExternalSourceGroup.ExternalSources` |
| UDTs | `$sw.TypeGroup.Types` |

## Create a block from SCL

```powershell
$fi  = New-Object System.IO.FileInfo('C:\temp\Scale.scl')
$src = $sw.ExternalSourceGroup.ExternalSources.CreateFromFile('Scale', $fi)
$src.GenerateBlocksFromSource()     # compiles SCL/AWL text into real blocks
$src.Delete()                       # optional: drop the source object
```

## Import / export SimaticML XML

```powershell
$sw.BlockGroup.Blocks.Import((New-Object IO.FileInfo 'fc.xml'), [Siemens.Engineering.ImportOptions]::Override)
$block.Export((New-Object IO.FileInfo 'out.xml'), [Siemens.Engineering.ExportOptions]::WithDefaults)
```

## Compile

```powershell
$icomp = [Siemens.Engineering.Compiler.ICompilable]
$mi = [Siemens.Engineering.IEngineeringServiceProvider].GetMethod('GetService').MakeGenericMethod($icomp)
$result = $mi.Invoke($sw, $null).Compile()      # or invoke on a single block
$result.State; $result.ErrorCount; $result.Messages
```

## Common data types & addresses

- Types: `Bool, Byte, Word, DWord, Int, DInt, Real, LReal, Time, String, Char`, UDT/`"MyType"`.
- Addresses: `%I0.0` (input bit), `%Q0.1` (output), `%M10.0` (memory bit), `%MW20` (memory word),
  `%IW64` (analog in), `%DB1.DBX0.0` (data bit).

## Gotchas

- `Attach()` → `EngineeringSecurityException` = not in `Siemens TIA Openness` group (re-login after adding).
- A first-run whitelist dialog can appear for a new calling exe; approving once persists it.
- Openness version must match a running Portal of the same major version to attach to it.
- `try/catch` is not a valid PowerShell *expression*; use the module's `Get-Safe { }` helper inside hashtables.
- One process = one Openness version. Restart PowerShell to switch V19 ⇄ V21.
