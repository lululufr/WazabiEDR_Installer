#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Orchestrate the full WazabiEDR install in the order required by
    Inno Setup.

.DESCRIPTION
    Runs install-driver.ps1 then post-install.ps1, propagating exit
    codes (in particular 3010 = reboot required). Picked over chained
    [Run] sections in setup.iss because Inno Setup does not stop a
    pipeline on a non-zero exit code from PowerShell, and we need the
    second script to NOT run if the driver install bailed out for a
    reboot.

.PARAMETER PackageDir
    Forwarded to install-driver.ps1 (where WazabiEDR_Driver.sys, .inf,
    .cer, .cat live -- bundled by the installer under {tmp}\driver).

.PARAMETER AgentExe
    Forwarded to post-install.ps1 — full path to WazabiEDR_Agent.exe
    inside the install dir.

.PARAMETER Server
    Forwarded to post-install.ps1 — WazabiEDR server URL.

.PARAMETER Token
    Forwarded to post-install.ps1 — enrollment token.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$PackageDir,
    [Parameter(Mandatory=$true)] [string]$AgentExe,
    [Parameter(Mandatory=$true)] [string]$Server,
    [Parameter(Mandatory=$true)] [string]$Token
)

$ErrorActionPreference = "Continue"

# Marker file lu par le oneliner PowerShell après setup.exe — contourne
# le fait qu'Inno Setup avale silencieusement les exit codes 3010/1641
# du [Run] et termine setup.exe en exit 0. Le oneliner ne pourrait
# alors pas savoir qu'un reboot est nécessaire et afficherait un
# faux "Done" à l'opérateur.
$RebootMarker = Join-Path $env:ProgramData "WazabiEDR\.reboot-required"

function Write-RebootMarker([string]$reason) {
    $dir = Split-Path -Parent $RebootMarker
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $stamp = (Get-Date).ToString("o")
    Set-Content -Path $RebootMarker -Value "stamped=$stamp; reason=$reason" -Encoding ascii
}

# Si un marker traînait d'un run précédent et qu'on tourne maintenant
# (donc post-reboot, l'opérateur a relancé l'install), on le purge :
# il sera ré-écrit si install-driver re-réclame un reboot. Évite un
# faux positif si l'install passe entièrement cette fois.
if (Test-Path $RebootMarker) {
    Remove-Item -Force $RebootMarker -ErrorAction SilentlyContinue
}

# 1. Driver install. Sur 3010 (test signing activé / vieux driver
#    locked), on écrit le marker et on stoppe : post-install n'a pas
#    de sens tant que le driver n'est pas chargeable.
& "$PSScriptRoot\install-driver.ps1" -PackageDir $PackageDir
$driverExit = $LASTEXITCODE
if ($driverExit -eq 3010) {
    Write-Host "[install-all] driver install reports reboot required (3010)" -ForegroundColor Yellow
    Write-RebootMarker "install-driver.ps1 exit 3010"
    exit 3010
}
if ($driverExit -ne 0) {
    Write-Host "[install-all] install-driver.ps1 exit code $driverExit -- stopping" -ForegroundColor Yellow
    exit $driverExit
}

# 2. Agent service + config + start.
& "$PSScriptRoot\post-install.ps1" -AgentExe $AgentExe -Server $Server -Token $Token
$postExit = $LASTEXITCODE
if ($postExit -ne 0) {
    exit $postExit
}

exit 0
