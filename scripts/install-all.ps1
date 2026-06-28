#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Orchestrate the full WazabiEDR install : driver -> post-install,
    with automatic reboot + resume when test signing or driver swap
    requires a restart.

.DESCRIPTION
    Première passe (depuis setup.exe Inno Setup) :
      install-driver.ps1   ── exit 3010 ──┐
                                          │ stage state + driver pkg
                                          │ register scheduled task
                                          │ Restart-Computer -Force
                                          ▼
                                   ────[ REBOOT ]────
                                          │
                                          ▼
    Resume au boot (task SYSTEM, AtStartup + 30s) :
      install-all.ps1 -ResumeFromState
        ├─ relit state.json (Server, Token, AgentExe, PackageDir staged)
        ├─ install-driver.ps1 — test signing est ON maintenant, exit 0
        ├─ post-install.ps1   — service + agent.json + start
        └─ cleanup : task, state file, driver pkg staged

    Le marker file %ProgramData%\WazabiEDR\.reboot-required est
    encore écrit en parallèle (rétro-compat avec un oneliner serveur
    qui le checke), mais le reboot lui-même est fait ici — l'opérateur
    n'a rien à faire entre les deux phases.

.PARAMETER PackageDir
.PARAMETER AgentExe
.PARAMETER Server
.PARAMETER Token
    Args normaux passés par Inno Setup au premier run.

.PARAMETER ResumeFromState
    Switch interne — la scheduled task post-reboot passe ce flag.
    Les autres args sont alors ignorés et lus depuis le state file.
#>
[CmdletBinding()]
param(
    [string]$PackageDir,
    [string]$AgentExe,
    [string]$Server,
    [string]$Token,
    [switch]$ResumeFromState
)

$ErrorActionPreference = "Continue"

$ConfigDir       = Join-Path $env:ProgramData "WazabiEDR"
$RebootMarker    = Join-Path $ConfigDir ".reboot-required"
$StatePath       = Join-Path $ConfigDir ".resume-state.json"
$ResumeDriverDir = Join-Path $ConfigDir ".resume-driver-pkg"
$ResumeTaskName  = "WazabiEDR-Resume-Install"
$LogPath         = Join-Path $ConfigDir "install.log"

# Redirige stdout + stderr vers un fichier ET la console. Sans ça,
# quand on tourne depuis Inno Setup [Run] toute la sortie part dans
# le néant et on debug à l'aveugle. Le fichier survit aux reboots, on
# peut donc inspecter le log de la première phase après resume.
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}
Start-Transcript -Path $LogPath -Append -IncludeInvocationHeader | Out-Null

# ---- Mode resume : relit les args depuis le state ------------------------
if ($ResumeFromState) {
    if (-not (Test-Path $StatePath)) {
        Write-Host "[install-all] -ResumeFromState set but $StatePath not found — abort" -ForegroundColor Red
        exit 1
    }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $PackageDir = $state.PackageDir
    $AgentExe   = $state.AgentExe
    $Server     = $state.Server
    $Token      = $state.Token
    Write-Host "[install-all] resume mode : PackageDir=$PackageDir Server=$Server" -ForegroundColor Cyan
} else {
    # Premier run normal : args obligatoires.
    if (-not $PackageDir -or -not $AgentExe -or -not $Server -or -not $Token) {
        Write-Host "[install-all] missing required args (PackageDir, AgentExe, Server, Token)" -ForegroundColor Red
        exit 1
    }
}

# Purge un éventuel marker laissé par une exécution précédente. Sera
# ré-écrit plus bas si install-driver redemande un reboot.
if (Test-Path $RebootMarker) {
    Remove-Item -Force $RebootMarker -ErrorAction SilentlyContinue
}

# ---- Fonctions helpers ---------------------------------------------------

function Save-ResumeState {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    }
    # Stage le PackageDir en local : Inno Setup va supprimer le {tmp}
    # original avec son flag deleteafterinstall, et au boot suivant il
    # n'existera plus.
    if (Test-Path $ResumeDriverDir) {
        Remove-Item -Recurse -Force $ResumeDriverDir -ErrorAction SilentlyContinue
    }
    Copy-Item -Recurse -Force $PackageDir $ResumeDriverDir
    $obj = [ordered]@{
        Server     = $Server
        Token      = $Token
        AgentExe   = $AgentExe
        PackageDir = $ResumeDriverDir
    }
    $json = $obj | ConvertTo-Json
    Set-Content -Path $StatePath -Value $json -Encoding ascii
    # Marker file consommé en parallèle par le oneliner serveur (rétro-compat).
    $stamp = (Get-Date).ToString("o")
    Set-Content -Path $RebootMarker -Value "stamped=$stamp" -Encoding ascii
}

function Register-ResumeTask {
    # Self-path : on est dans {app}\scripts\install-all.ps1 ; cf. install.iss
    $scriptPath = $PSCommandPath
    if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
        # Fallback : Inno installe systématiquement le script à ce chemin.
        $scriptPath = "C:\Program Files\WazabiEDR\scripts\install-all.ps1"
    }
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`"", "-ResumeFromState"
    ) -join " "
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args
    # AtStartup + delay 30s : laisse le temps à PnP/SCM/réseau d'être up.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT30S"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable -DontStopOnIdleEnd `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $ResumeTaskName `
        -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "WazabiEDR: resume install after reboot. Auto-removed on success." `
        -Force | Out-Null
}

function Clear-ResumeState {
    # Appelé en cas d'install complète (premier run OK, ou resume OK).
    $task = Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item -Force $StatePath -ErrorAction SilentlyContinue
    Remove-Item -Force $RebootMarker -ErrorAction SilentlyContinue
    if (Test-Path $ResumeDriverDir) {
        Remove-Item -Recurse -Force $ResumeDriverDir -ErrorAction SilentlyContinue
    }
}

# ---- 1. Driver -----------------------------------------------------------
& "$PSScriptRoot\install-driver.ps1" -PackageDir $PackageDir
$driverExit = $LASTEXITCODE

if ($driverExit -eq 3010) {
    Write-Host "[install-all] driver install reports reboot required (3010)" -ForegroundColor Yellow
    Write-Host "[install-all] staging state and registering resume task" -ForegroundColor Cyan
    Save-ResumeState
    Register-ResumeTask

    Write-Host "[install-all] REBOOT in 10 seconds — install will resume automatically" -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    # Restart-Computer -Force kill tous les processes utilisateurs ; setup.exe
    # va remonter exit 0 (déjà passé) mais l'opérateur ne verra pas la fin
    # du oneliner — le post-install se fera au boot suivant via la task.
    Restart-Computer -Force
    # Si Restart-Computer return (très rare), on remonte quand même 3010
    # pour que le oneliner sache.
    exit 3010
}

if ($driverExit -ne 0) {
    Write-Host "[install-all] install-driver.ps1 exit code $driverExit -- stopping" -ForegroundColor Yellow
    exit $driverExit
}

# ---- 2. Agent service + config + start -----------------------------------
& "$PSScriptRoot\post-install.ps1" -AgentExe $AgentExe -Server $Server -Token $Token
$postExit = $LASTEXITCODE

if ($postExit -ne 0) {
    exit $postExit
}

# ---- 3. Cleanup resume state (si on en avait) ----------------------------
Clear-ResumeState
Write-Host "[install-all] install complete" -ForegroundColor Green
Stop-Transcript | Out-Null
exit 0
