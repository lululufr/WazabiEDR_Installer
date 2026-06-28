# Server-side bootstrap

The WazabiEDR server (FastAPI, see `WazabiEDR_Server/`) is responsible
for rendering the PowerShell one-liner that operators execute on each
endpoint to install the agent.

## Where the URL comes from

The single source of truth is the `PUBLIC_URL` env var consumed by
`WazabiEDR_Server`:

| File | What it does |
|---|---|
| `WazabiEDR_Server/.env.example` | Documents `PUBLIC_URL=…`; the operator copies to `.env` and adjusts. |
| `WazabiEDR_Server/app/config.py` | `settings.public_url: str \| None` — pydantic-settings reads it from `.env`. |
| `WazabiEDR_Server/app/routers/install.py` | `_resolve_server_url(request)` — uses `settings.public_url` when set, falls back to the request's Host header otherwise. |

Set `PUBLIC_URL` explicitly in production. The Host-header fallback is
fine for dev (a `curl http://localhost:8000/api/v1/install/agent`
gets a script that points back at `localhost`) but a misconfigured
reverse proxy in prod could leak an internal URL into the install
scripts shipped to endpoints.

## The current `/install/agent` endpoint

`WazabiEDR_Server/app/routers/install.py` already exposes:

- `GET /api/v1/install/agent?platform=windows` → returns a PowerShell
  script that enrols and configures the agent. **Currently targets the
  legacy single-binary design** (`/install/binary` serves a standalone
  `wazabi-agent.exe`, no driver, no `wedr-plugin`).
- `GET /api/v1/install/binary` → serves the agent binary from
  `settings.agent_installer_path`.

## Hooking the new `WazabiEDR_Setup_X.Y.Z.exe` flow

To switch the server from the legacy single-binary script to the
Inno Setup installer produced by this repo, `install.py` needs:

1. A way to learn the **installer release URL + SHA-256**. Two options:
   - Static config: add `INSTALLER_URL` + `INSTALLER_SHA256` env vars,
     bumped manually each release.
   - Dynamic: call GitHub's
     `GET /repos/{owner}/WazabiEDR_Installer/releases/latest`,
     parse `assets[]` for `WazabiEDR_Setup_*.exe` + `SHA256SUMS`.
     Cache server-side. More moving parts but no manual bump on release.

2. A rewrite of `_build_powershell_installer` to mirror the template
   in [`install.ps1.tmpl`](./install.ps1.tmpl) — download setup.exe,
   verify SHA-256, run silent with `/SERVER=<PUBLIC_URL> /TOKEN=<JWT>`.

3. The `ENROLLMENT_TOKEN` env var is already consumed; nothing to
   change there.

That rewrite is **not part of the installer skeleton** in this repo —
the template is here as a reference for whoever picks up the
server-side change.

## Operator one-liner (target state)

```powershell
iwr http://wazabi.example.com:8080/api/v1/install/agent -UseBasicParsing | iex
```

The server reads `PUBLIC_URL=http://wazabi.example.com:8080` from its
`.env`, renders the template with that URL + a freshly-minted
enrollment token + the current installer's URL/SHA-256, and the
endpoint runs it.

## Reboot semantics

Setup exit code 3010 → bootstrap exits 3010 too. The calling
deployment tool (RMM, MDM, ad-hoc PowerShell) is expected to handle
the reboot and re-run the one-liner. Enrollment tokens should be
single-use; the server is responsible for either reissuing or
detecting "this endpoint already enrolled, just hand back the same
agent_id" on retry — a hard 401 here would break every reboot-after-
install flow.
