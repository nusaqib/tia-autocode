# Linking a project repo to the engine (worked example: PPS_SR)

How a **private, per-machine project repo** consumes this **public engine** as a git
submodule - the two-repo strategy, and the exact steps, verified against a real repo
(`PPS_SR`).

## The strategy: engine vs. project repos

Two layers, deliberately separate:

| Layer | Repo | Contains | Visibility |
|---|---|---|---|
| **Engine** | `tia-autocode` (this repo) | the `TiaOpenness` module, generator, validator, templates, skills, docs | **public** |
| **Project** | one per machine (e.g. `PPS_SR`) | the manifest + exported CSV/XLSX + SCL + HMI XML + build output | **private** |

Why split them:

- **Customer/machine data never touches the public engine.** All of PPS_SR's tags, logic,
  and hardware live in the private PPS_SR repo.
- **The engine is reused, not copied.** Every project pins the engine at a specific commit
  (a git submodule), so a machine that shipped keeps building the same way forever, and you
  upgrade the engine deliberately (by moving the pin), never by accident.
- **Offline validation everywhere.** The project repo's CI runs `Test-TiaSpec` (no TIA
  needed) on every push; the actual TIA build happens on an engineering PC with Openness.

```
tia-autocode/  (public engine)                 PPS_SR/  (private project)
  src/TiaOpenness/  module ......................  engine/         <- submodule, pinned
  templates/  reusable SCL/UDT                     project.yaml    <- the machine
  docs/ skills/ ...                                data/*.csv|xlsx
                                                   logic/*.scl
                                                   hmi/*.xml
                                                   build.ps1 / validate.ps1
                                                   .github/workflows/validate.yml
```

## Step 1 - scaffold the project repo

From a machine that has the engine module imported:

```powershell
Import-Module <engine>\src\TiaOpenness\TiaOpenness.psd1 -Force
New-TiaProjectRepo -Path E:\TIA_Portal\PPS_SR -Name PPS_SR
```

This writes a ready skeleton: `project.yaml`, starter `data/*.csv`, `logic/FB_Motor.scl`,
`build.ps1`, `validate.ps1`, an offline-validation CI workflow, `.gitignore`, and a README -
with the machine name filled in. (You can also copy `engine/src/TiaOpenness/project-template`
by hand; the cmdlet just does the copy + name substitution.)

## Step 2 - init the repo and link the engine

```bash
cd E:/TIA_Portal/PPS_SR
git init
git add -A && git commit -m "Scaffold PPS_SR project repo from tia-autocode template"
git submodule add https://github.com/nusaqib/tia-autocode.git engine
git commit -am "Add tia-autocode engine as submodule at engine/"
```

`git submodule add` clones the engine into `engine/` and records the pin in `.gitmodules`:

```ini
[submodule "engine"]
    path = engine
    url = https://github.com/nusaqib/tia-autocode.git
```

`git submodule status` shows the pinned commit, e.g. `92a8fed... engine (heads/main)`.

## Step 3 - author the machine

- **Data** in `data/*.csv` (tags, UDTs, DBs, rack modules, HMI tags). A workbook works too:
  reference a sheet as `data/PLC_1.xlsx#Tags`.
- **Logic** in `logic/*.scl`, or instantiate an engine template in the manifest:
  `logic: [ { template: MotorStarter, params: { Name: FB_Conveyor } } ]`.
- **Hardware/HMI**: set the real CPU and panel order numbers in `project.yaml`.
- **Naming**: the `naming:` section lints names (advisory warnings via `Test-TiaSpec`).

### Adopting an existing machine (recommended for PPS_SR)

PPS_SR already exists as a live TIA project. Seed the repo from it instead of hand-typing,
on the TIA PC (read-only against the live project):

```powershell
Import-Module .\engine\src\TiaOpenness\TiaOpenness.psd1 -Force
Connect-TiaPortal                                   # attach to the running Portal (read)
Export-TiaToSpec -OutDir . -PlcName PLC_1           # tags/modules -> CSV, UDTs/blocks -> XML, project.json
```

Commit the exported CSV/XML and diff future changes. Know-how/safety-protected (F) blocks
are skipped with a warning - see Safety below.

## Step 4 - validate offline (CI + local)

```powershell
powershell -ExecutionPolicy Bypass -File .\validate.ps1
```

Verified on the freshly-linked PPS_SR skeleton:

```
Spec: Errors: 0, Warnings: 0
Spec OK.
```

`.github/workflows/validate.yml` runs this on `windows-latest` on every push/PR. It checks
out the submodule (`submodules: recursive`) and imports the pinned engine - so CI validates
the spec with zero TIA install. Keep it green.

## Step 5 - build on a TIA machine

On a Windows PC with TIA Portal + Openness (and the `Siemens TIA Openness` group active):

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Validates, then `Invoke-TiaBuildFromSpec` creates the project under `_out/PPS_SR`
(gitignored), adds the CPU + rack, generates UDTs/logic/DBs/tags, creates the HMI panel,
compiles, and snapshots to `generated/`.

## Cloning the project repo elsewhere

The submodule is a pin, not a copy - a fresh clone must pull it:

```bash
git clone <PPS_SR remote> PPS_SR
cd PPS_SR
git submodule update --init --recursive     # fetch the engine at the pinned commit
```

## Upgrading the engine (moving the pin)

The pin is intentional - the machine keeps building against a known engine. Upgrade only
when you choose to:

```bash
cd engine && git fetch && git checkout <new-commit-or-tag> && cd ..
git commit -am "Bump engine to <new-commit>"    # records the new pin
```

Re-run `validate.ps1` after bumping; if it stays green, the upgrade is safe for this machine.

## Safety

- The live PPS_SR project is **read-only by policy** - generate into a scratch project
  (`portal.new: true`, `build.save` to your own `_out/`), never the human's `.ap19`.
- **Safety (F) blocks** cannot be exported or modified via Openness until the safety program
  is unlocked in TIA; the engine never bypasses that. `Export-TiaToSpec` skips protected
  blocks with a warning.
- Keep customer data in the **private** project repo only; the public engine needs none of it.
