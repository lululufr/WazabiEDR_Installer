# WazabiEDR_Installer

Inno Setup script that produces `WazabiEDR_Setup_X.Y.Z.exe`, the single-file
installer for WazabiEDR endpoints.

## What it installs

| Component | Source | Destination |
|---|---|---|
| Kernel driver (KMDF) | release of `WazabiEDR_Driver` | Driver Store + `Root\WazabiEDR_Driver` PnP device + service `WazabiEDR_Driver` |
| User-mode agent | release of `WazabiEDR_Agent` | `{app}\agent\WazabiEDR_Agent.exe` + service `WazabiEDR_Agent` (auto-start) |
| Operator CLI | release of `WazabiEDR_Utils` | `{app}\bin\wedr-plugin.exe` (added to machine `PATH`) |
| Initial config | generated | `%ProgramData%\WazabiEDR\agent.json` (Administrators/SYSTEM ACL) |

`{app}` defaults to `C:\Program Files\WazabiEDR`.

## Layout

```
WazabiEDR_Installer/
├── setup.iss                  # Inno Setup script
├── scripts/
│   ├── install-driver.ps1     # called from setup.iss [Run]
│   ├── post-install.ps1       # service + agent.json + start
│   ├── install-all.ps1        # orchestrator (driver → post)
│   └── uninstall-pre.ps1      # called from [UninstallRun]
├── .github/workflows/
│   └── build.yml              # tag v* → download deps, ISCC, release
└── payload/                   # populated at build time (gitignored)
    ├── agent/
    ├── driver/
    └── utils/
```

## Building locally (no GitHub required)

Use this flow in dev or before the GitHub release pipeline is in
place — the server can serve the produced EXE directly via
`INSTALLER_LOCAL_FILE` (cf. WazabiEDR_Server/.env.example).

Prerequisites:

- Inno Setup 6 (`winget install JRSoftware.InnoSetup`)
- The Rust toolchain (MSVC) and cargo-make for the driver
- The four sibling repos checked out next to each other (parent dir
  containing `WazabiEDR_Driver/`, `WazabiEDR_Agent/`,
  `WazabiEDR_Utils/`, `WazabiEDR_Installer/`)

```powershell
# Build everything and drop the EXE into the server's modules dir.
# `..\WazabiEDR_Server\modules\` is the host side of the bind-mount
# defined in WazabiEDR_Server/docker-compose.yml ->
# ./modules:/app/modules:ro.
cd C:\path\to\WazabiEDR_Installer
.\scripts\build-local.ps1 -Version 0.1.0 -DeployTo ..\WazabiEDR_Server\modules\
```

The script :

1. Builds the driver (`cargo make` in `WazabiEDR_Driver/`).
2. Builds the agent (`cargo build --release` in `WazabiEDR_Agent/`).
3. Builds the operator CLI (`cargo build --release` in `WazabiEDR_Utils/`).
4. Stages everything under `payload/`.
5. Runs `ISCC.exe /DAppVersion=0.1.0 setup.iss`.
6. With `-DeployTo`: copies the result as `WazabiEDR_Setup.exe`
   (unversioned name so the server's `INSTALLER_LOCAL_FILE` doesn't
   need bumping) into the target directory.

Iterating on the installer alone (when `payload/` is already
populated):

```powershell
.\scripts\build-local.ps1 -SkipDriver -SkipAgent -SkipUtils -DeployTo ..\WazabiEDR_Server\modules\
```

Then on the server side:

```bash
# In WazabiEDR_Server/.env
INSTALLER_LOCAL_FILE=/app/modules/WazabiEDR_Setup.exe
```

Restart the API (`docker compose restart api`) and hit
<http://server:8080/console/install> — the page shows mode LOCAL with
the SHA-256 auto-computed.

## Running the installer

### Interactive (GUI)

Launch `WazabiEDR_Setup_0.1.0.exe` as Administrator. The wizard prompts
for **Server URL** and **Enrollment token** before installing.

### Silent (server-driven one-liner)

```powershell
.\WazabiEDR_Setup_0.1.0.exe /SILENT /SERVER=http://wazabi.example.com:8080 /TOKEN=eyJhbGciOi...
```

The server listens on port `8080` by default (see the agent's
default skeleton in `WazabiEDR_Agent/src/config.rs`). Adjust the
URL to match your deployment.

Both `/SERVER=` and `/TOKEN=` are required in silent mode. The wizard
returns a non-zero exit code if either is missing.

### Reboot semantics

`install-driver.ps1` returns **3010** when:

- test signing was just turned on (`bcdedit /set testsigning on`) and
  the new state needs a reboot to take effect, or
- the previously-loaded driver has no `DriverUnload` routine and can
  only be replaced after a reboot.

Inno Setup recognises exit code 3010 (thanks to `RestartIfNeededByRun=yes`
in `setup.iss`) and prompts the user / sets the reboot-required flag.
In silent mode the installer exits 0 but signals reboot needed via the
standard MSI-compatible reboot exit code; the calling script should
schedule a restart.

## Uninstall

Standard "Add/remove programs" entry. The uninstaller:

1. Stops + deletes `WazabiEDR_Agent` (Windows service)
2. Removes the `Root\WazabiEDR_Driver` PnP device and evicts the INF
   from the Driver Store
3. Stops + deletes `WazabiEDR_Driver`
4. Removes `{app}\bin` from machine PATH
5. Deletes the install dir

`%ProgramData%\WazabiEDR\` (config, spool, rules, plugins manifest)
is **preserved** — the operator may want to keep state across a
re-install. Wipe manually with `Remove-Item -Recurse $env:ProgramData\WazabiEDR`.

## CI

`.github/workflows/build.yml` triggers on `push: tags: 'v*'`:

1. Downloads matching release artefacts from sibling repos
   (`WazabiEDR_Driver`, `WazabiEDR_Agent`, `WazabiEDR_Utils`) via
   `gh release download`.
2. Lays them out under `payload/`.
3. Runs `ISCC.exe /DAppVersion=$tag setup.iss`.
4. Uploads `out\WazabiEDR_Setup_X.Y.Z.exe` to this repo's release.

Sibling repos must have a release tagged with the same `vX.Y.Z`.
