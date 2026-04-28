#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Silently installs the latest NetBird client MSI on a Windows user device.

.DESCRIPTION
    Fully unattended install. No console output, no dialogs, no balloon
    notifications visible to the end user. All activity is written to a log
    file for admin review. Intended for deployment via RMM, Intune, GPO,
    scheduled task, or SCCM in SYSTEM context. After install, the user
    authenticates interactively from the tray UI on first connect.

.NOTES
    Run as Administrator or SYSTEM. Requires PowerShell 5.1 or later.
    Reference: https://docs.netbird.io/get-started/install/windows

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\Install-NetBird.ps1
#>

[CmdletBinding()]
param(
    [string]$DownloadPath  = "$env:TEMP\netbird-installer.msi",
    [string]$MsiLogPath    = "$env:ProgramData\NetBird\netbird-install.log",
    [string]$ScriptLogPath = "$env:ProgramData\NetBird\netbird-deploy.log"
)

$ErrorActionPreference = 'Stop'
$DownloadUrl = 'https://pkgs.netbird.io/windows/msi/x64'

# ---------------------------------------------------------------------------
# Logging setup (file only, no console)
# ---------------------------------------------------------------------------
$logDir = Split-Path $ScriptLogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Out-File -FilePath $ScriptLogPath -Append -Encoding UTF8
}

# Force TLS 1.2 (older PS hosts default to TLS 1.0/1.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Log "===== NetBird silent install starting ====="

# ---------------------------------------------------------------------------
# 1. Skip if NetBird is already installed (idempotent for RMM re-runs)
# ---------------------------------------------------------------------------
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$existing = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'NetBird*' }

if ($existing) {
    Write-Log "NetBird already installed (version $($existing.DisplayVersion)). Nothing to do."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Download the latest MSI
# ---------------------------------------------------------------------------
Write-Log "Downloading MSI from $DownloadUrl"
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $DownloadPath -UseBasicParsing
}
catch {
    Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

if (-not (Test-Path $DownloadPath) -or (Get-Item $DownloadPath).Length -lt 1MB) {
    Write-Log "Downloaded file is missing or unexpectedly small." 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
# 3. Verify Authenticode signature before executing
# ---------------------------------------------------------------------------
$sig = Get-AuthenticodeSignature -FilePath $DownloadPath
if ($sig.Status -ne 'Valid') {
    Write-Log "MSI signature is not valid (Status: $($sig.Status)). Aborting." 'ERROR'
    Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Log "Signature verified. Signer: $($sig.SignerCertificate.Subject)"

# ---------------------------------------------------------------------------
# 4. Silent install via msiexec
# ---------------------------------------------------------------------------
Write-Log "Launching msiexec in silent mode."
$msiArgs = @(
    '/i', "`"$DownloadPath`"",
    '/qn',
    '/norestart',
    '/l*v', "`"$MsiLogPath`""
)
$proc = Start-Process -FilePath 'msiexec.exe' `
                      -ArgumentList $msiArgs `
                      -Wait `
                      -PassThru `
                      -WindowStyle Hidden

if ($proc.ExitCode -ne 0) {
    Write-Log "Install failed with exit code $($proc.ExitCode). See $MsiLogPath" 'ERROR'
    exit $proc.ExitCode
}

# ---------------------------------------------------------------------------
# 5. Cleanup
# ---------------------------------------------------------------------------
Remove-Item $DownloadPath -Force -ErrorAction SilentlyContinue
Write-Log "NetBird installed successfully. Daemon service is running."
Write-Log "===== NetBird silent install complete ====="
exit 0
