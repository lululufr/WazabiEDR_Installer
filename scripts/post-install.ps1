#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Register the agent as a Windows service, seed agent.json, start
    the service.

.DESCRIPTION
    Called by the Inno Setup installer after binaries have been
    laid down. Idempotent: a second invocation will refresh the
    binPath and restart the service without overwriting an
    operator-edited agent.json.

    Exit codes:
      0   success
      1   generic failure

.PARAMETER AgentExe
    Full path to WazabiEDR_Agent.exe (typically
    "C:\Program Files\WazabiEDR\agent\WazabiEDR_Agent.exe").

.PARAMETER Server
    URL of the WazabiEDR server. Written verbatim into
    agent.json -> shipper.server_url. Required.

.PARAMETER Token
    Enrollment token. Written into agent.json ->
    shipper.enrollment_token. The agent will exchange it for a
    permanent agent_id + bearer token on first boot, via the
    config's auto-enroll path (see WazabiEDR_Agent/src/config.rs).
    Required.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AgentExe,

    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$true)]
    [string]$Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServiceName = "WazabiEDR_Agent"
$DisplayName = "WazabiEDR Agent"
$Description = "Userland endpoint agent for WazabiEDR. Pumps kernel events from the WazabiEDR_Driver, spools them locally as zstd-compressed NDJSON batches and forwards them to the configured server."

$ConfigDir   = Join-Path $env:ProgramData "WazabiEDR"
$ConfigPath  = Join-Path $ConfigDir "agent.json"
$SpoolDir    = Join-Path $ConfigDir "spool"

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Fail([int]$code, [string]$m) {
    Write-Host "[-] $m" -ForegroundColor Red
    exit $code
}

if (-not (Test-Path $AgentExe)) {
    Fail 1 "Agent binary not found: $AgentExe"
}

# ---- 1. Service entry ------------------------------------------------------
# sc.exe query exits 1060 when the service does not exist; anything
# else means it's already registered and we update binPath in place
# (the installer may be doing an upgrade).
& sc.exe query $ServiceName | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Step "Service '$ServiceName' already registered -- updating binPath"
    & sc.exe config $ServiceName binPath= "`"$AgentExe`"" start= auto | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 1 "sc config failed (exit $LASTEXITCODE)" }
} else {
    Write-Step "Creating service '$ServiceName'"
    & sc.exe create $ServiceName binPath= "`"$AgentExe`"" start= auto DisplayName= "$DisplayName" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 1 "sc create failed (exit $LASTEXITCODE)" }
    & sc.exe description $ServiceName "$Description" | Out-Null
}

# Restart-on-crash policy: 5s, 10s, 30s backoff, then give up. The
# 86400-second reset window means a stable run of 24h clears the
# failure count.
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

# ---- 2. Config directory ---------------------------------------------------
if (-not (Test-Path $ConfigDir)) {
    Write-Step "Creating $ConfigDir"
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}
if (-not (Test-Path $SpoolDir)) {
    New-Item -ItemType Directory -Force -Path $SpoolDir | Out-Null
}

# ---- 3. Seed agent.json ----------------------------------------------------
# Never overwrite an operator-edited file. A re-install reads whatever
# is on disk; the new server URL / token reaches the running agent only
# when the operator clears the existing config and re-runs setup.
if (Test-Path $ConfigPath) {
    Write-Step "$ConfigPath already exists -- not overwriting"
} else {
    Write-Step "Writing initial agent.json"

    $config = [ordered]@{
        agent = [ordered]@{
            console_output     = $false
            spool_dir          = $SpoolDir
            max_bytes_per_file = 1048576
            max_age_secs       = 10
            max_total_bytes    = 268435456
            channel_capacity   = 1024
            zstd_level         = 3
        }
        shipper = [ordered]@{
            enabled            = $true
            server_url         = $Server
            enrollment_token   = $Token
            agent_id           = ""
            token_plain        = ""
            verify_tls         = $true
            timeout_secs       = 30
            poll_interval_secs = 5
            max_backoff_secs   = 300
        }
        control = [ordered]@{
            enabled                 = $true
            heartbeat_interval_secs = 60
            send_alerts             = $true
        }
        etw = [ordered]@{
            enabled    = $true
            dns        = $true
            tcp        = $true
            powershell = $true
            wmi        = $true
            schannel   = $true
            amsi       = $true
        }
        polling = [ordered]@{
            enabled               = $true
            services              = $true
            scheduled_tasks       = $true
            interval_secs         = 30
            silent_first_snapshot = $true
        }
    }

    $json = $config | ConvertTo-Json -Depth 8
    # utf8 (no BOM) -- serde_json on the agent side reads bytes
    # directly, a BOM at offset 0 would fail JSON parse.
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding $false))

    # Restrict ACL to Administrators + SYSTEM. The file contains the
    # enrollment token (plaintext until auto-enroll succeeds) and the
    # post-enrollment bearer token (DPAPI-encrypted normally, but
    # plain during the bootstrap window). Same trust boundary as
    # %ProgramData%\WazabiEDR\plugins\.
    $acl = Get-Acl $ConfigPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    $admins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators", "FullControl", "Allow")
    $system = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "Allow")
    $acl.AddAccessRule($admins)
    $acl.AddAccessRule($system)
    Set-Acl -Path $ConfigPath -AclObject $acl
    Write-Ok "agent.json written + ACL restricted to Administrators/SYSTEM"
}

# ---- 4. Start the service --------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction Stop
if ($svc.Status -ne "Running") {
    Write-Step "Starting service '$ServiceName'"
    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
    } catch {
        # Don't fail the installer on a service start error -- the
        # binaries are in place and the operator can investigate
        # (likely cause: driver still pending a reboot, or invalid
        # server URL rejected by auto-enroll). They can re-run
        # `sc start WazabiEDR_Agent` later.
        Write-Host "[!] Could not start service: $_" -ForegroundColor Yellow
        Write-Host "    Setup leaves the service installed; run 'sc start $ServiceName' once the issue is resolved." -ForegroundColor Yellow
        exit 0
    }
    Start-Sleep -Seconds 2
    $svc.Refresh()
}
Write-Ok "Agent service running. State: $($svc.Status)"
exit 0
