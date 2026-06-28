#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install the WazabiEDR kernel driver from a pre-built package
    directory.

.DESCRIPTION
    Subset of WazabiEDR_Driver/build.ps1 stripped down to the
    install half (build is done in CI). Designed to be invoked by
    the Inno Setup installer in silent mode -- no interactive
    prompts, deterministic exit codes:

      0    success
      1    generic failure
      3010 reboot required (Windows convention)

    Test signing is enabled if absent (returns 3010). An existing
    driver that cannot be stopped (no DriverUnload routine) also
    returns 3010 so the wizard can ask for a reboot and retry.

.PARAMETER PackageDir
    Directory holding WazabiEDR_Driver.sys, WazabiEDR_Driver.inf,
    *.cer, *.cat (the cargo-make package output).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PackageDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServiceName = "WazabiEDR_Driver"
$InfName     = "WazabiEDR_Driver.inf"
$HardwareId  = "Root\WazabiEDR_Driver"

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok  ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail([int]$code, [string]$m) {
    Write-Host "[-] $m" -ForegroundColor Red
    exit $code
}

# ---- 1. Package validation -------------------------------------------------
if (-not (Test-Path $PackageDir)) {
    Fail 1 "Package directory not found: $PackageDir"
}
$infPath = Join-Path $PackageDir $InfName
if (-not (Test-Path $infPath)) {
    Fail 1 "$InfName not found in $PackageDir"
}
$sysPath = Join-Path $PackageDir "$ServiceName.sys"
if (-not (Test-Path $sysPath)) {
    Fail 1 "$ServiceName.sys not found in $PackageDir"
}
Write-Ok "Package validated: $PackageDir"

# ---- 2. Test signing -------------------------------------------------------
# The driver is signed with a self-issued test certificate (cargo-make
# pipeline); Windows will only load it if testsigning mode is on. We
# enable it here if absent and return 3010 so the Inno Setup wizard
# prompts for a reboot -- the change only takes effect after.
$tsEnabled = (bcdedit /enum "{current}") -match "testsigning\s+Yes"
if (-not $tsEnabled) {
    Write-Warn "Test signing disabled. Enabling..."
    bcdedit /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail 1 "bcdedit /set testsigning on failed -- Secure Boot may be blocking. Disable Secure Boot in firmware then re-run setup."
    }
    Fail 3010 "Test signing enabled -- reboot required before driver install can proceed."
}
Write-Ok "Test signing active"

# ---- 3. Locate devcon.exe --------------------------------------------------
$arch = if ([Environment]::Is64BitOperatingSystem) {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
} else { "x86" }

$devcon = Get-ChildItem -Path "C:\Program Files (x86)\Windows Kits\10\Tools" `
    -Filter "devcon.exe" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\$arch\\" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $devcon) {
    Fail 1 "devcon.exe ($arch) not found. Install the Windows Driver Kit (WDK)."
}
Write-Ok "devcon: $devcon"

# ---- 4. Detect and remove any prior install --------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        Write-Step "Stopping existing service '$ServiceName' (state: $($svc.Status))..."
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
        } catch {
            # No DriverUnload routine -- only a reboot can swap it.
            # Disable so the old version doesn't reload at next boot,
            # then ask the wizard for a reboot.
            & sc.exe config $ServiceName start= disabled | Out-Null
            Fail 3010 "Existing driver is locked (no DriverUnload). Reboot required, then re-run setup to finish the install."
        }
    }
}

$devices = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like "Root\$ServiceName*" }
foreach ($d in $devices) {
    Write-Step "Removing PnP device: $($d.InstanceId)"
    pnputil /remove-device $d.InstanceId | Out-Null
    Start-Sleep -Milliseconds 200
}

# Driver Store entries published under previous oemNN.inf names. Without
# this, pnputil /add-driver below would create a fresh oemNN.inf and the
# old one would linger forever in the Driver Store.
$pnpBlocks = ((pnputil /enum-drivers) -join "`n") -split "(?=Published Name:)"
$oldOemNames = $pnpBlocks |
    Where-Object { $_ -match "Original Name:\s+$InfName" } |
    ForEach-Object { if ($_ -match "Published Name:\s+(oem\d+\.inf)") { $Matches[1] } }
foreach ($oem in $oldOemNames) {
    Write-Step "Removing from Driver Store: $oem"
    pnputil /delete-driver $oem /uninstall /force | Out-Null
}

# ---- 5. Install the test certificate ---------------------------------------
$certFile = Get-ChildItem $PackageDir -Filter "*.cer" -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($certFile) {
    Write-Step "Installing certificate: $($certFile.Name)"
    certutil -addstore -f "Root"             $certFile.FullName | Out-Null
    certutil -addstore -f "TrustedPublisher" $certFile.FullName | Out-Null
    Write-Ok "Certificate installed (Root + TrustedPublisher)"
} else {
    Write-Warn "No .cer in $PackageDir -- pnputil /add-driver may fail"
}

# ---- 6. Install the new driver ---------------------------------------------
Write-Step "Adding package to Driver Store: $infPath"
pnputil /add-driver $infPath
if ($LASTEXITCODE -ne 0) {
    Fail 1 "pnputil /add-driver failed (exit $LASTEXITCODE)"
}

Write-Step "Creating root device '$HardwareId' via devcon..."
& $devcon install $infPath $HardwareId
if ($LASTEXITCODE -ne 0) {
    Fail 1 "devcon install failed (exit $LASTEXITCODE)"
}
Start-Sleep -Seconds 2

# ---- 7. Start the service --------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Fail 1 "Service '$ServiceName' not detected after devcon install"
}

# devcon install may have inherited 'disabled' from the recovery branch
# above. Flip back to demand. Idempotent.
& sc.exe config $ServiceName start= demand | Out-Null

$svc.Refresh()
if ($svc.Status -ne "Running") {
    Write-Step "Starting service '$ServiceName'..."
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 2
    $svc.Refresh()
}

Write-Ok "Driver running. State: $($svc.Status)"
exit 0
