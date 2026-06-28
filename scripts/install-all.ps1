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

# 1. Driver install. On a reboot-required result (3010) we stop here:
#    the agent service relies on the driver being loaded to receive
#    events, and the operator must reboot before we configure +
#    start the agent.
& "$PSScriptRoot\install-driver.ps1" -PackageDir $PackageDir
$driverExit = $LASTEXITCODE
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
