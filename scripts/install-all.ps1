#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Orchestrate the full WazabiEDR install : driver then post-install,
    with automatic reboot + resume when test signing or driver swap
    requires a restart.

.DESCRIPTION
    Premiere passe (depuis setup.exe Inno Setup):
      install-driver.ps1 -- exit 3010 --> stage state + driver pkg
                                     --> register scheduled task
                                     --> Restart-Computer -Force

                          (REBOOT)

    Resume au boot (task SYSTEM, AtStartup + 30s):
      install-all.ps1 -ResumeFromState
        - relit state.json (Server, Token, AgentExe, PackageDir staged)
        - install-driver.ps1 -- test signing est ON maintenant, exit 0
        - post-install.ps1   -- service + agent.json + start
        - cleanup: task, state file, driver pkg staged

    Le marker file %ProgramData%\WazabiEDR\.reboot-required est aussi
    ecrit en parallele (retro-compat avec un oneliner serveur qui le
    checke), mais le reboot lui-meme est fait ici -- l operateur n a
    rien a faire entre les deux phases.

.PARAMETER PackageDir
.PARAMETER AgentExe
.PARAMETER Server
.PARAMETER Token
    Args passes par Inno Setup au premier run.

.PARAMETER ResumeFromState
    Switch interne -- la scheduled task post-reboot passe ce flag.
    Les autres args sont alors ignores et lus depuis le state file.

.NOTE
    Tout le code de ce fichier est en pur ASCII : PowerShell 5.1
    lit les .ps1 en ANSI (cp1252) par defaut, et un caractere UTF-8
    multi-octets (em dash, accents) declenche un ParserError au
    chargement -- le script n est meme pas execute. Pas d em dash
    ni accent dans ce fichier.
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

$ConfigDir         = Join-Path $env:ProgramData "WazabiEDR"
$RebootMarker      = Join-Path $ConfigDir ".reboot-required"
$StatePath         = Join-Path $ConfigDir ".resume-state.json"
$ResumeDriverDir   = Join-Path $ConfigDir ".resume-driver-pkg"
$ResumeTaskName    = "WazabiEDR-Resume-Install"
$ResumeUITaskName  = "WazabiEDR-Resume-UI"
$LogPath           = Join-Path $ConfigDir "install.log"

# Redirige stdout + stderr vers un fichier ET la console. Sans ca,
# quand on tourne depuis Inno Setup [Run] toute la sortie part dans
# le neant et on debug a l aveugle. Le fichier survit aux reboots,
# on peut donc inspecter le log de la premiere phase apres resume.
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}
Start-Transcript -Path $LogPath -Append | Out-Null

# ---- Mode resume : relit les args depuis le state ------------------------
if ($ResumeFromState) {
    if (-not (Test-Path $StatePath)) {
        Write-Host "[install-all] -ResumeFromState set but $StatePath not found, abort" -ForegroundColor Red
        Stop-Transcript | Out-Null
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
        Write-Host "[install-all] missing required args" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}

# Purge un eventuel marker laisse par une execution precedente. Sera
# re-ecrit plus bas si install-driver redemande un reboot.
if (Test-Path $RebootMarker) {
    Remove-Item -Force $RebootMarker -ErrorAction SilentlyContinue
}

# ---- Fonctions helpers ---------------------------------------------------

function Save-ResumeState {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    }
    # Stage le PackageDir en local : Inno Setup va supprimer le {tmp}
    # original avec son flag deleteafterinstall, et au boot suivant
    # il n existera plus.
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
    # Marker file consomme en parallele par le oneliner serveur.
    $stamp = (Get-Date).ToString("o")
    Set-Content -Path $RebootMarker -Value "stamped=$stamp" -Encoding ascii
}

function Register-ResumeTask {
    # Self-path : on est dans {app}\scripts\install-all.ps1.
    $scriptPath = $PSCommandPath
    if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
        $scriptPath = "C:\Program Files\WazabiEDR\scripts\install-all.ps1"
    }
    $taskArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$scriptPath`"", "-ResumeFromState"
    ) -join " "
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
    # AtStartup + delay 30s : laisse le temps a PnP/SCM/reseau d etre up.
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
        -Description "WazabiEDR resume install after reboot. Auto-removed on success." `
        -Force | Out-Null
}

function Register-ResumeUITask {
    # Task qui affiche une UI WPF au prochain logon utilisateur. Elle
    # tail install.log et show le statut des services, en parallele de
    # la SYSTEM task qui drive l install. Self-clean quand l agent
    # service est Running.
    $uiScript = Join-Path (Split-Path -Parent $PSCommandPath) "resume-ui.ps1"
    if (-not (Test-Path $uiScript)) {
        # Fallback : chemin canonique de l install
        $uiScript = "C:\Program Files\WazabiEDR\scripts\resume-ui.ps1"
    }
    $taskArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Normal",
        "-File", "`"$uiScript`""
    ) -join " "
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # Limited principal : la UI ne lit que install.log et query les
    # services (read-only). Pas besoin d admin.
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable
    Unregister-ScheduledTask -TaskName $ResumeUITaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName $ResumeUITaskName `
        -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "WazabiEDR resume install UI. Self-removed once the agent service is running." `
        -Force | Out-Null
}

function Clear-ResumeState {
    foreach ($name in @($ResumeTaskName, $ResumeUITaskName)) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        }
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
    Write-Host "[install-all] staging state and registering resume tasks" -ForegroundColor Cyan
    Save-ResumeState
    Register-ResumeTask
    Register-ResumeUITask

    Write-Host "[install-all] REBOOT in 10 seconds, install will resume automatically" -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 10
    # Restart-Computer -Force kill tous les processes utilisateurs ;
    # setup.exe va remonter exit 0 (deja passe) mais l operateur ne
    # verra pas la fin du oneliner -- le post-install se fera au boot
    # suivant via la task.
    Restart-Computer -Force
    # Si Restart-Computer return (tres rare), on remonte 3010 quand meme.
    exit 3010
}

if ($driverExit -ne 0) {
    Write-Host "[install-all] install-driver.ps1 exit code $driverExit, stopping" -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    exit $driverExit
}

# ---- 2. Agent service + config + start -----------------------------------
# Capture $LASTEXITCODE AVANT le call pour pouvoir detecter si
# post-install n a meme pas tourne (ParserError ou autre erreur de
# chargement) : dans ce cas $LASTEXITCODE reste a 0 (succes de
# install-driver precedent) et on annonce un faux succes. On veut
# detecter ce cas via le check du service Agent juste apres.
$LASTEXITCODE = 0
& "$PSScriptRoot\post-install.ps1" -AgentExe $AgentExe -Server $Server -Token $Token
$postExit = $LASTEXITCODE

if ($postExit -ne 0) {
    Write-Host "[install-all] post-install.ps1 exit code $postExit, stopping" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit $postExit
}

# Defensive check : meme avec exit code 0, si post-install n a pas
# tourne (ParserError silencieux sur ANSI codepage), le service Agent
# n est jamais cree. On verifie l effet attendu avant d annoncer
# succes a la UI / au caller.
Start-Sleep -Seconds 1
$agentSvc = Get-Service -Name "WazabiEDR_Agent" -ErrorAction SilentlyContinue
if (-not $agentSvc) {
    Write-Host "[install-all] post-install.ps1 returned 0 but service WazabiEDR_Agent was not created" -ForegroundColor Red
    Write-Host "[install-all] probable silent ParserError in post-install.ps1, check the transcript above" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 2
}

# ---- 3. Cleanup resume state (si on en avait) ----------------------------
Clear-ResumeState
Write-Host "[install-all] install complete" -ForegroundColor Green
Stop-Transcript | Out-Null
exit 0
