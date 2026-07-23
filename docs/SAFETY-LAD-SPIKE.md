# Feasibility spike: LAD generation, safety (F) blocks, distributed ET200SP

Live results (TIA V19 + Openness, scratch F-CPU) establishing what Openness allows for a
distributed **fail-safe** system programmed in **LAD** - the basis for generating the
SR PPS project (and a future engine capability). Every item below was run end-to-end.

## Summary - what works

| Capability | Result |
|---|---|
| Author **LAD** (FlgNet SimaticML) -> import -> **compile** | ✅ 0 errors/0 warnings |
| Author **F-LAD** F-FB in the safety program -> import -> compile | ✅ 0 errors (1 benign "not called" warning) |
| Export F-FB / F-DB (learn F-block schema) | ✅ works (only the system F-runtime OB `FOB_RTG1` is protected) |
| F-module 1oo2 / discrepancy parameters in the API | ✅ `Siemens.Engineering.HW.Failsafe_*` enums present |
| Create **ET200SP** PROFINET station (IM) via Openness | ✅ `6ES7155-6AU01-0CN0/V4.2` |
| Plug an **F-DI** onto the ET200SP `Rack_0` | ✅ `6ES7136-6BA01-0CA0/V1.0`, position 1 |

**Conclusion:** generating a distributed F-system in LAD via Openness is feasible. No
part of the toolchain is a dead end.

## LAD block schema (proven minimal rung)

A LAD block is `SW.Blocks.FC/FB/OB` with `ProgrammingLanguage = LAD` and a
`CompileUnit` whose `NetworkSource` holds an `FlgNet` (namespace
`.../SW/NetworkSource/FlgNet/v5`). The block `AttributeList` **must** include the full
ordered set (`AutoNumber, Header*, HeaderVersion, Interface, IsIECCheckEnabled,
MemoryLayout, Name, Namespace, Number, ProgrammingLanguage, SetENOAutomatically`) - a
missing `Namespace` etc. is rejected.

Minimal rung = powerrail -> NO contact -> coil:
- Parts: two `Access` (operands) + `Part Name="Contact"` + `Part Name="Coil"`.
  A normally-open contact is just `<Part Name="Contact" UId="..."/>` - **no** `negated`
  TemplateValue (that fails the `TemplateType_TE` enum). Negation would be a
  `<Negated Name="operand"/>` child.
- Wires: `Powerrail -> contact.in`, `operandAccess -> contact.operand`,
  `contact.out -> coil.in`, `operandAccess -> coil.operand` (via `IdentCon`/`NameCon`).

Working files: [`reference/lad/FC_LadTest.xml`](reference/lad/FC_LadTest.xml) (plain LAD),
[`reference/lad/FB_SafeTest.xml`](reference/lad/FB_SafeTest.xml) (F-LAD, safety).

## Safety (F) specifics

- An F-FB is an ordinary `SW.Blocks.FB` with `ProgrammingLanguage = F_LAD` (or `F_FBD`)
  plus `UDABlockProperties` / `UDAEnableTagReadback` attributes. Importing one places it
  in the safety program; the whole-PLC compile includes the safety run-time.
- The system-generated F-run-time OB (`FOB_RTG1`) is export-protected - do not author it;
  author the F-FBs it calls. The F-DB and F main FB export fine.
- Operands in an F-FB rung can be the block's own interface members
  (`Access Scope="LocalVariable"`).

## Distributed ET200SP + F-modules

- Create the station: `project.Devices.CreateWithItem('OrderNumber:6ES7155-6AU01-0CN0/V4.2', name, name)`.
  It yields `Rack_0`, the IM head with a **PROFINET interface**, and a bus adapter.
- Plug peripherals onto `Rack_0` with `PlugNew(orderNumber, name, position)` - **the
  order number needs a firmware version** (`.../0CA0/V1.0`); `CanPlugNew` finds valid
  position/version combos. The engine's `Add-TiaModule` (central-rack oriented) does not
  find the ET200SP rack - distributed plugging needs the `Rack_0`-targeted call above.

## Still to work out during the BTA build (known-doable, not blockers)

1. **PROFINET controller assignment** - connect each ET200SP IM to the CPU's PROFINET
   IO system (subnet + IO controller) so modules get addresses and the project compiles.
2. **Exact 1oo2 F-parameter navigation** - the `Failsafe_*` parameters (sensor
   evaluation 1oo2, discrepancy time/behavior) sit on the F-DI **channel sub-items**, not
   the module's top attribute list; set them there. In-module 1oo2 pairs both contacts of
   a device onto one module's paired channels (the agreed approach - safety review flag).
3. **Engine capability** - fold the proven LAD/F-LAD emission + ET200SP plugging into
   `TiaOpenness` cmdlets (a LAD-rung builder + `New-TiaIoDevice`) once BTA validates them.
