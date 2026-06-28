#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tear-down counterpart of install-driver.ps1 + post-install.ps1.

.DESCRIPTION
    Called from the [UninstallRun] section of setup.iss BEFORE Inno
    Setup removes files. Stops + deletes both Windows services
    (agent, driver), removes the PnP root device, evicts the
    driver-store INF.

    Configuration (%ProgramData%\WazabiEDR\) is NOT removed -- the
    operator may want to preserve spool batches and rules across a
    reinstall. Run `Remove-Item -Recurse $env:ProgramData\WazabiEDR`
    manually to wipe state.

    Exit code is always 0 -- a partial teardown should not block
    the uninstaller. Failures are printed for the operator to see.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$AgentService  = "WazabiEDR_Agent"
$DriverService = "WazabiEDR_Driver"
$DriverInf     = "WazabiEDR_Driver.inf"
$HardwareId    = "Root\WazabiEDR_Driver"

# Le script vit dans {app}\scripts\ ; on remonte d'un cran pour
# retrouver {app} = la racine d'install (Program Files\WazabiEDR).
$InstallRoot     = Split-Path -Parent $PSScriptRoot
$ConfigDir       = Join-Path $env:ProgramData "WazabiEDR"
$AgentExe        = Join-Path $InstallRoot "agent\WazabiEDR_Agent.exe"
$FwRuleName      = "WazabiEDR Agent — Outbound"
$ResumeTaskName  = "WazabiEDR-Resume-Install"
$ResumeStatePath = Join-Path $ConfigDir ".resume-state.json"
$RebootMarker    = Join-Path $ConfigDir ".reboot-required"
$ResumeDriverDir = Join-Path $ConfigDir ".resume-driver-pkg"

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# ---- 1. Stop + delete the agent service -----------------------------------
$svc = Get-Service -Name $AgentService -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        Write-Step "Stopping $AgentService"
        try { Stop-Service -Name $AgentService -Force -ErrorAction Stop } catch {
            Write-Warn "Stop-Service $AgentService failed: $_"
        }
        Start-Sleep -Seconds 2
    }
    Write-Step "Deleting service $AgentService"
    & sc.exe delete $AgentService | Out-Null
}

# ---- 2. Tear down the driver ----------------------------------------------
# Devices first (devcon remove) so the driver service can stop, then
# pnputil /delete-driver evicts the INF from the store.
$devcon = Get-ChildItem -Path "C:\Program Files (x86)\Windows Kits\10\Tools" `
    -Filter "devcon.exe" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\x64\\" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName

$devices = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like "Root\$DriverService*" }
foreach ($d in $devices) {
    Write-Step "Removing PnP device: $($d.InstanceId)"
    pnputil /remove-device $d.InstanceId | Out-Null
    Start-Sleep -Milliseconds 200
}

$svc = Get-Service -Name $DriverService -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne "Stopped") {
    Write-Step "Stopping $DriverService"
    try { Stop-Service -Name $DriverService -Force -ErrorAction Stop } catch {
        Write-Warn "Driver stop failed (no DriverUnload?) -- will be cleared on next reboot. $_"
    }
}
if ($svc) {
    & sc.exe delete $DriverService | Out-Null
}

# Driver Store eviction.
$pnpBlocks = ((pnputil /enum-drivers) -join "`n") -split "(?=Published Name:)"
$oldOemNames = $pnpBlocks |
    Where-Object { $_ -match "Original Name:\s+$DriverInf" } |
    ForEach-Object { if ($_ -match "Published Name:\s+(oem\d+\.inf)") { $Matches[1] } }
foreach ($oem in $oldOemNames) {
    Write-Step "Removing from Driver Store: $oem"
    pnputil /delete-driver $oem /uninstall /force | Out-Null
}

# ---- 3. Firewall rule -----------------------------------------------------
$existing = Get-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Removing firewall rule '$FwRuleName'"
    Remove-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue
}

# ---- 4. Defender exclusions -----------------------------------------------
# Remove-MpPreference est aussi silencieux que Add quand la cible
# n'existe pas. Le try/catch couvre le cas Tamper Protection / Defender
# absent — symetrique de post-install.ps1.
try {
    Remove-MpPreference -ExclusionPath $InstallRoot -ErrorAction SilentlyContinue
    Remove-MpPreference -ExclusionPath $ConfigDir -ErrorAction SilentlyContinue
    Remove-MpPreference -ExclusionProcess $AgentExe -ErrorAction SilentlyContinue
} catch {
    Write-Warn "Could not clean up Defender exclusions: $_"
}

# ---- 5. Resume state -----------------------------------------------------
# Si l'opérateur désinstalle alors qu'un cycle reboot/resume est en
# cours (post-reboot pas encore relancé), on retire la task + state
# pour éviter que l'install ne se relance toute seule au prochain
# boot vers des binaires qui n'existent plus.
$task = Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Step "Removing pending resume task '$ResumeTaskName'"
    Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}
Remove-Item -Force $ResumeStatePath -ErrorAction SilentlyContinue
Remove-Item -Force $RebootMarker -ErrorAction SilentlyContinue
if (Test-Path $ResumeDriverDir) {
    Remove-Item -Recurse -Force $ResumeDriverDir -ErrorAction SilentlyContinue
}

Write-Ok "Teardown complete. %ProgramData%\WazabiEDR is preserved."
exit 0
