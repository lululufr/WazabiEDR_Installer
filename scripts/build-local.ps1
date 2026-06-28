#Requires -Version 5.1
<#
.SYNOPSIS
    Build WazabiEDR_Setup_X.Y.Z.exe entirely locally, no GitHub
    required.

.DESCRIPTION
    Builds the three sibling components, lays them out under
    `payload/`, then runs ISCC.exe to produce
    `out/WazabiEDR_Setup_<Version>.exe`. Use this in dev / before the
    GitHub release pipeline is in place — the server can serve this
    EXE directly via INSTALLER_LOCAL_FILE.

.PARAMETER Version
    AppVersion stamped into the EXE (Inno Setup `/DAppVersion=`).
    Defaults to "0.1.0-dev".

.PARAMETER WazabiRoot
    Path to the parent directory holding the four sibling repos
    (Driver, Agent, Utils, Installer). Defaults to the grandparent
    of this script.

.PARAMETER SkipDriver
.PARAMETER SkipAgent
.PARAMETER SkipUtils
    Skip a component build (assume payload/<comp>/ is already
    populated). Handy when iterating on the installer script alone.

.PARAMETER DeployTo
    If set, copies the produced EXE to this path after build. Pass
    the server's modules dir (e.g. `..\WazabiEDR_Server\modules\`)
    to avoid a manual copy step. Path must already exist.

.EXAMPLE
    # Build everything and drop the EXE next to the server's modules
    .\scripts\build-local.ps1 -DeployTo ..\WazabiEDR_Server\modules\

.EXAMPLE
    # Rebuild only the installer (payload already there)
    .\scripts\build-local.ps1 -SkipDriver -SkipAgent -SkipUtils
#>
[CmdletBinding()]
param(
    [string]$Version = "0.1.0-dev",
    [string]$WazabiRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$SkipDriver,
    [switch]$SkipAgent,
    [switch]$SkipUtils,
    [string]$DeployTo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$InstallerDir = Split-Path -Parent $PSScriptRoot
$PayloadDir   = Join-Path $InstallerDir "payload"
$OutDir       = Join-Path $InstallerDir "out"

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "[-] $m" -ForegroundColor Red; exit 1 }

# Resolve ISCC.exe lazily so we don't fail when the user only wants
# to rebuild a payload component.
function Get-Iscc {
    $candidates = @(
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    # PATH fallback (rare).
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    Fail "ISCC.exe not found. Install Inno Setup 6 (winget install JRSoftware.InnoSetup)."
}

# ---- Stage payload/ -------------------------------------------------------
New-Item -ItemType Directory -Force -Path $PayloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir     | Out-Null

# --- Driver ---------------------------------------------------------------
if (-not $SkipDriver) {
    $DriverRepo = Join-Path $WazabiRoot "WazabiEDR_Driver"
    if (-not (Test-Path $DriverRepo)) { Fail "Driver repo not found: $DriverRepo" }
    Write-Step "Building driver (cargo make) in $DriverRepo"
    # build.ps1 expects to run from its own dir; use Push-Location so
    # cargo-make picks up the right Makefile.toml. We pass -NoBuild=$false
    # implicitly (default) so the full make pipeline runs.
    Push-Location $DriverRepo
    try {
        # The driver build.ps1 also installs the driver locally — we
        # don't want that for an installer build. Run cargo make
        # directly instead.
        $env:CARGO_TARGET_DIR = $null
        & cargo make
        if ($LASTEXITCODE -ne 0) { Fail "cargo make failed for the driver" }
    } finally { Pop-Location }
    $driverPkg = Join-Path $DriverRepo "target\debug\WazabiEDR_Driver_package"
    if (-not (Test-Path $driverPkg)) { Fail "Driver package not produced at $driverPkg" }
    $driverDest = Join-Path $PayloadDir "driver"
    if (Test-Path $driverDest) { Remove-Item -Recurse -Force $driverDest }
    Copy-Item -Recurse -Force $driverPkg $driverDest
    Write-Ok "Driver package staged at $driverDest"
} else {
    Write-Warn "Skipping driver build (-SkipDriver)"
}

# --- Agent ----------------------------------------------------------------
if (-not $SkipAgent) {
    $AgentRepo = Join-Path $WazabiRoot "WazabiEDR_Agent"
    if (-not (Test-Path $AgentRepo)) { Fail "Agent repo not found: $AgentRepo" }
    Write-Step "Building agent (cargo build --release) in $AgentRepo"
    Push-Location $AgentRepo
    try {
        & cargo build --release --target x86_64-pc-windows-msvc
        if ($LASTEXITCODE -ne 0) { Fail "cargo build failed for the agent" }
    } finally { Pop-Location }
    $agentExe = Join-Path $AgentRepo "target\x86_64-pc-windows-msvc\release\WazabiEDR_Agent.exe"
    if (-not (Test-Path $agentExe)) { Fail "Agent binary not produced at $agentExe" }
    $agentDest = Join-Path $PayloadDir "agent"
    New-Item -ItemType Directory -Force -Path $agentDest | Out-Null
    Copy-Item -Force $agentExe (Join-Path $agentDest "WazabiEDR_Agent.exe")
    Write-Ok "Agent staged at $agentDest"
} else {
    Write-Warn "Skipping agent build (-SkipAgent)"
}

# --- Utils ----------------------------------------------------------------
if (-not $SkipUtils) {
    $UtilsRepo = Join-Path $WazabiRoot "WazabiEDR_Utils"
    if (-not (Test-Path $UtilsRepo)) { Fail "Utils repo not found: $UtilsRepo" }
    Write-Step "Building utils (cargo build --release) in $UtilsRepo"
    Push-Location $UtilsRepo
    try {
        & cargo build --release --target x86_64-pc-windows-msvc
        if ($LASTEXITCODE -ne 0) { Fail "cargo build failed for utils" }
    } finally { Pop-Location }
    $utilsExe = Join-Path $UtilsRepo "target\x86_64-pc-windows-msvc\release\wedr-plugin.exe"
    if (-not (Test-Path $utilsExe)) { Fail "wedr-plugin.exe not produced at $utilsExe" }
    $utilsDest = Join-Path $PayloadDir "utils"
    New-Item -ItemType Directory -Force -Path $utilsDest | Out-Null
    Copy-Item -Force $utilsExe (Join-Path $utilsDest "wedr-plugin.exe")
    Write-Ok "Utils staged at $utilsDest"
} else {
    Write-Warn "Skipping utils build (-SkipUtils)"
}

# ---- Compile setup.iss ---------------------------------------------------
$iscc = Get-Iscc
Write-Step "Running ISCC /DAppVersion=$Version"
Push-Location $InstallerDir
try {
    & $iscc "/DAppVersion=$Version" setup.iss
    if ($LASTEXITCODE -ne 0) { Fail "ISCC failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }

$outExe = Join-Path $OutDir "WazabiEDR_Setup_$Version.exe"
if (-not (Test-Path $outExe)) { Fail "Expected $outExe not produced" }

$sha = (Get-FileHash -Algorithm SHA256 -Path $outExe).Hash.ToLower()
$size = (Get-Item $outExe).Length
Write-Ok "Built $outExe ($([math]::Round($size/1MB, 2)) MB)"
Write-Ok "SHA-256: $sha"

# ---- Optional deploy -----------------------------------------------------
if ($DeployTo) {
    $resolved = Resolve-Path $DeployTo -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Fail "DeployTo path does not exist: $DeployTo"
    }
    if (-not (Test-Path $resolved -PathType Container)) {
        Fail "DeployTo must be a directory: $DeployTo"
    }
    # Always copy as the unversioned name so the server's
    # INSTALLER_LOCAL_FILE doesn't have to track the version.
    $deployed = Join-Path $resolved "WazabiEDR_Setup.exe"
    Copy-Item -Force $outExe $deployed
    Write-Ok "Deployed to $deployed"
    Write-Ok "Set in server .env: INSTALLER_LOCAL_FILE=/app/modules/WazabiEDR_Setup.exe"
}
