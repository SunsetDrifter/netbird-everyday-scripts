#Requires -Version 5.1

<#
.SYNOPSIS
    Deploys the NetBird Windows client in two phases: a silent machine-wide
    install, and a per-user provisioning step that reliably starts the tray UI.

.DESCRIPTION
    Two phases, because a NetBird deployment genuinely has two halves and they
    run under different identities.

    -Phase Install    Runs as SYSTEM or an elevated admin. Optionally writes the
                      management server into managed policy, downloads and
                      signature-verifies the MSI, installs silently, and
                      confirms the daemon service is running. This half is what
                      an RMM's "install as system" step should call.

    -Phase Provision  Runs as the signed-in user, in that user's own interactive
                      session, NOT elevated. Registers the peer and starts the
                      tray UI so that it lands on the user's desktop and stays
                      running after this script exits.

    -Phase Check      Read-only. Prints everything needed to diagnose a
                      "tunnel works but no tray icon" report.

    The daemon is a Windows service and runs fine from the install phase alone.
    The tray UI is a desktop application: started from a service or system
    context it exits with code 1 in about 90 ms, logs nothing an admin would
    find, and leaves no process. That is why a silent install can produce a
    working tunnel with no tray icon, and it is why the provision phase exists.

.NOTES
    PowerShell 5.1 compatible. Client v0.75.0 or later.
    Reference: https://docs.netbird.io/get-started/install/windows

    Do not mix installer channels. This script uses the MSI throughout.
    Running the NSIS .exe over an MSI install upgrades netbird-ui.exe but
    leaves the running daemon binary at the old version and registers a
    second uninstall entry.

.EXAMPLE
    # RMM step 1, as SYSTEM
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\Install-NetBird.ps1 `
        -Phase Install -ManagementUrl https://api.example.com -Version 0.75.1

.EXAMPLE
    # RMM step 2, as the signed-in user, not elevated
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-NetBird.ps1 -Phase Provision

.EXAMPLE
    # Anytime, to see why there is no tray icon
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-NetBird.ps1 -Phase Check
#>

[CmdletBinding()]
# Write-Host is deliberate, see the note in Write-Log: an RMM captures the
# console of the powershell.exe it launched, and this script's whole job is to
# be readable in that capture when a deployment goes wrong.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [ValidateSet('Install', 'Provision', 'Check')]
    [string]$Phase = 'Install',

    # Self-hosted management server. Omit entirely for NetBird Cloud.
    # The port is optional: the client appends :443 for https and :80 for http.
    [string]$ManagementUrl,

    # Dashboard URL, if it differs from the management URL. Provision phase only.
    [string]$AdminUrl,

    # Pin a release, for example '0.75.1'. Strongly recommended for fleet
    # rollouts: reproducible, and upgrades become a deliberate act. Omitted
    # means the pkgs.netbird.io "latest" redirect, which moves under you.
    [string]$Version,

    # Path to a file containing only a setup key. Provision phase. Omitted
    # means interactive SSO, which is the right default for user devices:
    # identity binds to the peer, so policy follows the person.
    [string]$SetupKeyFile,

    # Do not write ManagementURL into managed policy during the install phase.
    [switch]$SkipPolicy,

    # Reinstall even when NetBird is already present at the requested version.
    [switch]$Force,

    # Proceed with the provision phase from an elevated process. See the
    # comment on Start-TrayInUserSession before using this.
    [switch]$AllowElevated,

    # Seconds to wait for 'netbird up'. Generous on purpose: with interactive
    # SSO this covers a human finding the browser tab and signing in, and the
    # only job of the bound is to stop the script hanging forever when the
    # management server is unreachable.
    [int]$ConnectTimeoutSeconds = 300,

    # File-only logging, no console output. The original deployment default.
    [switch]$Quiet,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$PolicyKey      = 'HKLM:\Software\Policies\NetBird'
$ServiceName    = 'NetBird'
$RunKeyPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName   = 'netbird'
$ExpectedSigner = 'NetBird GmbH'
$TrayTaskName   = 'NetBird-Tray-FirstLaunch'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# The install phase logs to ProgramData, which only SYSTEM and Administrators
# can write. The user-context phases cannot use it, so they log under the
# user's own profile instead. Getting this wrong throws access-denied at the
# first log line, before anything useful has happened.
if (-not $LogPath) {
    $LogPath = if ($Phase -eq 'Install') {
        Join-Path $env:ProgramData 'NetBird\netbird-deploy.log'
    } else {
        Join-Path $env:LOCALAPPDATA 'NetBird\netbird-provision.log'
    }
}

$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line | Out-File -FilePath $LogPath -Append -Encoding UTF8
    # Write-Host, never Write-Output: Write-Output would join the return value
    # of every function that logs, and callers would silently receive arrays.
    if (-not $Quiet) { Write-Host $line }
}

function Stop-WithError {
    param([string]$Message, [int]$Code = 1)
    Write-Log $Message 'ERROR'
    exit $Code
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentSessionId {
    (Get-Process -Id $PID).SessionId
}

function Get-NetBirdInstall {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'NetBird*' } |
        Select-Object DisplayName, DisplayVersion, InstallLocation |
        # Sort as versions, not as strings: '0.9.0' sorts above '0.75.1'
        # lexically, which would pick the wrong install location on a box
        # carrying two uninstall entries. Anything unparseable sorts last.
        Sort-Object -Descending -Property @{
            Expression = {
                $v = $null
                if ([Version]::TryParse($_.DisplayVersion, [ref]$v)) { $v }
                else { [Version]'0.0.0' }
            }
        }
}

function Get-InstallDir {
    # Prefer what the installer recorded; fall back to the WiX default. Do not
    # rely on PATH: the MSI adds the directory to the system PATH, but only
    # processes started afterwards inherit it.
    # ProgramW6432 is the 64-bit Program Files even from a 32-bit host, where
    # ProgramFiles would resolve to the (x86) directory and find nothing.
    $recorded = (Get-NetBirdInstall | Select-Object -First 1).InstallLocation
    $roots = @($env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ }
    foreach ($candidate in @($recorded) + @($roots | ForEach-Object { Join-Path $_ 'Netbird' })) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'netbird.exe'))) {
            return $candidate.TrimEnd('\')
        }
    }
    return $null
}

function Get-PolicyValue {
    param([Parameter(Mandatory)] [string]$Name)
    (Get-ItemProperty -Path $PolicyKey -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Invoke-Native {
    <#
      Runs a console executable and returns its exit code and combined output
      without letting native stderr trip $ErrorActionPreference = 'Stop'.
      A non-zero exit is data here, not an exception: 'netbird status' against
      a stopped daemon is a legitimate answer to a question we are asking.
    #>
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0
    )
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -NoNewWindow `
                           -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Touching Handle caches it in the .NET Process object. Without this,
        # ExitCode comes back EMPTY once the process has exited, even though
        # WaitForExit returned true and HasExited is $true. Measured on Windows
        # Server 2022 / PS 5.1: 'cmd /c exit 7' reports ExitCode = '' without
        # this line and 7 with it. The visible symptom is a successful command
        # being reported as failed, which is worse than no report at all.
        $null = $p.Handle
        $timedOut = $false
        if ($TimeoutSeconds -gt 0) {
            if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                # Kill races the process exiting on its own. Losing that race
                # is the good outcome, so it is noted and not treated as a fault.
                try { $p.Kill() }
                catch { Write-Log "Process $($p.Id) exited while being stopped: $($_.Exception.Message)" }
                $p.WaitForExit(5000) | Out-Null
            }
        } else {
            $p.WaitForExit()
        }
        $text = @(
            (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
            (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        ) -join ''
        # Belt and braces on top of the Handle cache: if ExitCode is somehow
        # still unreadable, say so rather than letting an empty value compare
        # unequal to 0 and turn a success into a reported failure.
        $code = if ($timedOut) { -1 } else { $p.ExitCode }
        if ($null -eq $code) { $code = 'unknown' }

        [pscustomobject]@{
            ExitCode = $code
            TimedOut = $timedOut
            # -Raw returns a plain string, but bare Get-Content returns file
            # objects carrying provider note properties, which ConvertTo-Json
            # then expands into kilobytes of reflection noise. Force a string.
            Output   = [string]$text
        }
    }
    finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Install phase
# ---------------------------------------------------------------------------

function Wait-FileUnlocked {
    # Defender and other real-time scanners hold a freshly downloaded installer
    # open for a second or two. Signature checks and msiexec both fail on it.
    param([Parameter(Mandatory)] [string]$Path, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None')
            $fs.Close()
            return
        }
        catch { Start-Sleep -Milliseconds 500 }
    }
    Stop-WithError "Installer at $Path stayed locked for $TimeoutSeconds seconds."
}

function Set-ManagementPolicy {
    <#
      Writes the management server as managed policy rather than passing
      --management-url on every user's command line.

      Three reasons this is the better place for it:
        - It is machine-wide and set before the daemon's first config load, so
          the very first connection already points at the right server.
        - A ManagementURL policy value SILENTLY overrides a --management-url
          passed on the command line. Leaving both in place means the flag is
          decoration and the registry is in charge; better to be explicit.
        - The daemon re-reads policy once a minute, so changing servers later
          does not need a reinstall.

      Value names are matched case-insensitively; the casing here matches the
      upstream ADMX.
    #>
    param([Parameter(Mandatory)] [string]$Url)
    if (-not (Test-Path -LiteralPath $PolicyKey)) {
        New-Item -Path $PolicyKey -Force | Out-Null
    }
    New-ItemProperty -Path $PolicyKey -Name 'ManagementURL' -Value $Url `
                     -PropertyType String -Force | Out-Null
    Write-Log "Managed policy ManagementURL = $Url"
}

function Get-Architecture {
    <#
      Returns 'arm64' or 'amd64'.

      PROCESSOR_ARCHITECTURE alone is not enough: read from a 32-bit
      PowerShell host on a 64-bit machine it reports x86, and the RMM decides
      which host runs the script, not you. PROCESSOR_ARCHITEW6432 is set only
      in that WOW64 case and holds the real answer, so check it first.
    #>
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'ARM64') { 'arm64' } else { 'amd64' }
}

function Get-Installer {
    param([Parameter(Mandatory)] [string]$Destination)

    $arch = Get-Architecture

    if ($Version) {
        $tag  = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        $bare = $tag.TrimStart('v')
        $url  = "https://github.com/netbirdio/netbird/releases/download/$tag/netbird_installer_${bare}_windows_${arch}.msi"
        Write-Log "Downloading pinned MSI $tag ($arch)"
    }
    else {
        # The pkgs.netbird.io redirect names the x64 flavour 'x64', not 'amd64'.
        $slug = if ($arch -eq 'arm64') { 'arm64' } else { 'x64' }
        $url  = "https://pkgs.netbird.io/windows/msi/$slug"
        Write-Log "Downloading latest MSI ($arch). Pin a release with -Version for reproducible rollouts." 'WARN'
    }

    try {
        Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing
    }
    catch {
        Stop-WithError "Download failed from ${url}: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item $Destination).Length -lt 1MB) {
        Stop-WithError "Downloaded file is missing or unexpectedly small."
    }
    Wait-FileUnlocked -Path $Destination

    $sig = Get-AuthenticodeSignature -FilePath $Destination
    if ($sig.Status -ne 'Valid') {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        Stop-WithError "MSI signature is not valid (Status: $($sig.Status))."
    }
    # A valid signature only means somebody signed it. Check who.
    $subject = [string]$sig.SignerCertificate.Subject
    if ($subject -notmatch [regex]::Escape($ExpectedSigner)) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        Stop-WithError "MSI is signed by an unexpected publisher: $subject"
    }
    Write-Log "Signature verified. Signer: $subject"
}

function Invoke-InstallPhase {
    if (-not (Test-Elevated)) {
        Stop-WithError "The install phase needs SYSTEM or an elevated administrator."
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Invoke-WebRequest renders a progress bar even with no console attached,
    # and on Windows PowerShell 5.1 that costs roughly an order of magnitude on
    # a multi-megabyte download. Suppressing it is the single largest speedup
    # available to this script.
    $ProgressPreference = 'SilentlyContinue'

    $existing = Get-NetBirdInstall | Select-Object -First 1
    if ($existing -and -not $Force) {
        $wanted = $Version -replace '^v', ''
        if (-not $wanted -or $existing.DisplayVersion -like "$wanted*") {
            Write-Log "NetBird $($existing.DisplayVersion) already installed. Nothing to do."
            if ($ManagementUrl -and -not $SkipPolicy) { Set-ManagementPolicy -Url $ManagementUrl }
            return 0
        }
        Write-Log "Installed $($existing.DisplayVersion), requested $wanted. Upgrading in place."
    }

    # Policy before msiexec, deliberately. The daemon starts during the install
    # and writes its first config there and then, so writing the policy first
    # means that config is correct from birth rather than corrected later.
    if ($ManagementUrl -and -not $SkipPolicy) {
        Set-ManagementPolicy -Url $ManagementUrl
    }
    elseif ($ManagementUrl) {
        Write-Log "-SkipPolicy set: pass -ManagementUrl to the provision phase instead." 'WARN'
    }

    $msi    = Join-Path $env:TEMP 'netbird-installer.msi'
    $msiLog = Join-Path (Split-Path $LogPath -Parent) 'netbird-install.log'
    Get-Installer -Destination $msi

    # No AUTOSTART property is passed. It existed through v0.74.7 and wrote a
    # machine-wide Run entry; on v0.75.x it does not exist and passing it is
    # accepted silently with no effect, which makes any log line claiming it
    # suppressed autostart a lie. Launch at login is per-user from v0.75.0, set
    # by the tray UI on its first successful unelevated start, and suppressed
    # fleet-wide with the DisableAutostart managed policy value.
    Write-Log "Installing silently. MSI log: $msiLog"
    $proc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -WindowStyle Hidden `
        -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
    # See the note in Invoke-Native: an uncached handle can yield an empty
    # ExitCode. -Wait makes that far less likely, but an empty value here would
    # fail a successful install, so it is not worth relying on the difference.
    if ($null -eq $proc.ExitCode) {
        Stop-WithError "msiexec exit code could not be read. Check $msiLog before retrying."
    }

    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    # 3010 is ERROR_SUCCESS_REBOOT_REQUIRED. The install succeeded.
    if ($proc.ExitCode -notin @(0, 3010)) {
        Stop-WithError "Install failed with exit code $($proc.ExitCode). See $msiLog" $proc.ExitCode
    }
    if ($proc.ExitCode -eq 3010) { Write-Log "Install succeeded; a reboot is pending." 'WARN' }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Stop-WithError "Install reported success but the $ServiceName service is absent." }
    if ($svc.Status -ne 'Running') {
        Write-Log "$ServiceName service is $($svc.Status). Starting it."
        Start-Service -Name $ServiceName
    }

    $installed = Get-NetBirdInstall | Select-Object -First 1
    Write-Log "NetBird $($installed.DisplayVersion) installed, daemon service running."
    Write-Log "No tray icon appears yet. Run this script with -Phase Provision as the signed-in user."
    return 0
}

# ---------------------------------------------------------------------------
# Provision phase
# ---------------------------------------------------------------------------

function Connect-Peer {
    param([Parameter(Mandatory)] [string]$InstallDir)

    $exe  = Join-Path $InstallDir 'netbird.exe'
    $upArgs = @('up')

    $policyUrl = Get-PolicyValue -Name 'ManagementURL'
    if ($policyUrl) {
        Write-Log "Management URL comes from managed policy: $policyUrl"
        if ($ManagementUrl -and $ManagementUrl.TrimEnd('/') -ne $policyUrl.TrimEnd('/')) {
            # Not a warning about a failure: the connection will work. It is a
            # warning that the flag has no effect, so nobody edits it for an
            # hour wondering why the server never changes.
            Write-Log "-ManagementUrl $ManagementUrl is ignored while that policy value exists." 'WARN'
        }
    }
    elseif ($ManagementUrl) {
        $upArgs += @('--management-url', $ManagementUrl)
    }
    if ($AdminUrl) { $upArgs += @('--admin-url', $AdminUrl) }

    if ($SetupKeyFile) {
        if (-not (Test-Path -LiteralPath $SetupKeyFile)) {
            Stop-WithError "Setup key file not found: $SetupKeyFile"
        }
        # --setup-key-file, never --setup-key: a command line is readable by
        # any local user for as long as the process lives.
        $upArgs += @('--setup-key-file', $SetupKeyFile)
        Write-Log "Registering with a setup key file."
    }
    else {
        Write-Log "Registering interactively. A browser will open for sign-in."
    }

    # Bounded, because 'netbird up' against an unreachable management server
    # blocks indefinitely rather than failing.
    $r = Invoke-Native -FilePath $exe -Arguments $upArgs -TimeoutSeconds $ConnectTimeoutSeconds

    # Always echo what it said, whether it succeeded or not. With interactive
    # sign-in the CLI prints the sign-in URL here as well as opening a browser,
    # and that URL is the fallback when the browser does not open. Capturing it
    # into a log nobody reads and then discarding it would strip a user's only
    # way through. Setup keys are passed by file, so nothing secret is echoed.
    foreach ($line in ($r.Output -split "`r?`n" | Where-Object { $_.Trim() })) {
        Write-Log "netbird up      : $($line.Trim())"
    }

    if ($r.TimedOut) {
        Write-Log "'netbird up' did not finish within $ConnectTimeoutSeconds seconds and was stopped." 'WARN'
        Write-Log "With interactive sign-in this usually means nobody completed it. Check the management URL is reachable." 'WARN'
    }
    elseif ($r.ExitCode -ne 0) {
        Write-Log "'netbird up' reported a non-zero exit ($($r.ExitCode)). The status below is what counts." 'WARN'
    }

    # Report the outcome rather than assert it. A device that is not yet
    # signed in should still get its tray icon: that is how the user signs in.
    $status = Invoke-Native -FilePath $exe -Arguments @('status') -TimeoutSeconds 30
    $summary = ($status.Output -split "`r?`n" | Where-Object { $_ -match 'Management|Signal|Daemon|Status' }) -join '; '
    Write-Log "Daemon status: $summary"
}

function Start-TrayInUserSession {
    <#
      Launches the tray through a scheduled task with an Interactive principal
      instead of Start-Process, which solves two problems at once:

        - The task borrows the signed-in user's existing logon token, so the
          process always lands on that user's interactive desktop. Started from
          session 0 the tray exits with code 1 in about 90 ms and logs nothing.
        - The task is not a child of this script, so it survives an RMM that
          kills the script's process tree when the step finishes.

      No password is stored and no administrative rights are needed: an
      Interactive principal reuses a logon that already exists.

      RunLevel is deliberately Limited. On v0.75.x the tray enables launch at
      login for that user the first time it starts successfully, once, and only
      when that start is not elevated. Burning that one-time marker with an
      elevated launch costs the user their tray icon on every future sign-in,
      permanently, with nothing logged.
    #>
    param([Parameter(Mandatory)] [string]$InstallDir)

    $exe = Join-Path $InstallDir 'netbird-ui.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Stop-WithError "Tray UI not found at $exe" }

    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action    = New-ScheduledTaskAction -Execute $exe
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

    try {
        Register-ScheduledTask -TaskName $TrayTaskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $TrayTaskName
        Write-Log "Tray launch requested via scheduled task as $me."
        Start-Sleep -Seconds 5
    }
    finally {
        Unregister-ScheduledTask -TaskName $TrayTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-ProvisionPhase {
    $session = Get-CurrentSessionId
    if ($session -eq 0) {
        Write-Log "This phase is running in session 0, not a user's interactive session." 'ERROR'
        Write-Log "The tray UI cannot start here: it exits with code 1 in about 90 ms and logs nothing." 'ERROR'
        Stop-WithError "Point the RMM's user-context step at the signed-in user's session and re-run."
    }
    Write-Log "Interactive session $session as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."

    if (Test-Elevated) {
        if (-not $AllowElevated) {
            Write-Log "An elevated first tray launch silently skips launch at login for this user, permanently." 'ERROR'
            Write-Log "Run this phase unelevated, or pass -AllowElevated to proceed anyway, in which case the" 'ERROR'
            Stop-WithError "script writes the launch-at-login value itself to compensate."
        }
        Write-Log "-AllowElevated set. The Run value will be written directly, since the tray will not." 'WARN'
    }

    $installDir = Get-InstallDir
    if (-not $installDir) { Stop-WithError "NetBird is not installed. Run -Phase Install first." }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Stop-WithError "The $ServiceName service is absent. The install phase did not complete." }
    if ($svc.Status -ne 'Running') { Stop-WithError "The $ServiceName service is $($svc.Status), not Running." }

    Connect-Peer -InstallDir $installDir
    Start-TrayInUserSession -InstallDir $installDir

    # Verify the two things that actually matter, rather than assuming the
    # launch worked: a live tray process in this user's session, and the
    # per-user launch-at-login value that makes this a one-time problem.
    $tray = Get-Process -Name 'netbird-ui' -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $session }
    if ($tray) {
        Write-Log "Tray running: pid $($tray[0].Id) in session $($tray[0].SessionId)."
    }
    else {
        Write-Log "No netbird-ui process in session $session after launch. See -Phase Check." 'WARN'
    }

    $run = (Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
    if ($run) {
        Write-Log "Launch at login is set for this user. The tray returns on its own at every sign-in."
    }
    elseif ($AllowElevated -and (Test-Elevated)) {
        $value = '"{0}"' -f (Join-Path $installDir 'netbird-ui.exe')
        New-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value $value `
                         -PropertyType String -Force | Out-Null
        Write-Log "Wrote launch at login for this user, since the elevated tray launch would not."
    }
    else {
        Write-Log "Launch at login is not set for this user. Check the DisableAutostart policy value." 'WARN'
    }
    return 0
}

# ---------------------------------------------------------------------------
# Check phase
# ---------------------------------------------------------------------------

function Invoke-CheckPhase {
    $session = Get-CurrentSessionId
    Write-Log "identity        : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "session         : $session$(if ($session -eq 0) { '  (session 0: the tray cannot start from here)' })"
    Write-Log "elevated        : $(Test-Elevated)"

    $install = Get-NetBirdInstall
    if ($install) {
        foreach ($i in $install) { Write-Log "installed       : $($i.DisplayName) $($i.DisplayVersion)" }
        if ($install.Count -gt 1) {
            Write-Log "Two uninstall entries usually means an MSI install was upgraded with the .exe." 'WARN'
        }
    }
    else { Write-Log "installed       : no" 'WARN' }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Write-Log "service         : $(if ($svc) { $svc.Status } else { 'absent' })"

    if (Test-Path -LiteralPath $PolicyKey) {
        $p = Get-ItemProperty -Path $PolicyKey
        foreach ($n in ($p.PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' })) {
            $v = if ($n -eq 'PreSharedKey') { '********** (secret)' } else { $p.$n }
            Write-Log "policy          : $n = $v"
        }
    }
    else { Write-Log "policy          : none" }

    $dir = Get-InstallDir
    if ($dir) {
        $r = Invoke-Native -FilePath (Join-Path $dir 'netbird.exe') -Arguments @('status') -TimeoutSeconds 30
        foreach ($line in ($r.Output -split "`r?`n" | Where-Object { $_.Trim() })) {
            Write-Log "status          : $($line.Trim())"
        }
    }

    $tray = Get-Process -Name 'netbird-ui' -ErrorAction SilentlyContinue
    if ($tray) {
        foreach ($t in $tray) { Write-Log "tray            : pid $($t.Id) session $($t.SessionId)" }
    }
    else { Write-Log "tray            : not running" 'WARN' }

    # Only meaningful when this phase runs as the user in question. Under
    # SYSTEM, HKCU is SYSTEM's own hive and says nothing about anybody else.
    if ($session -eq 0) {
        Write-Log "launch at login : not readable from session 0 (HKCU here is SYSTEM's hive)"
    }
    else {
        $run = (Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
        Write-Log "launch at login : $(if ($run) { $run } else { 'not set' })"
    }
    return 0
}

# ---------------------------------------------------------------------------

Write-Log "===== NetBird deploy, phase $Phase ====="
try {
    $code = switch ($Phase) {
        'Install'   { Invoke-InstallPhase }
        'Provision' { Invoke-ProvisionPhase }
        'Check'     { Invoke-CheckPhase }
    }
}
catch {
    Stop-WithError "Unhandled error: $($_.Exception.Message)"
}
Write-Log "===== phase $Phase complete ====="
exit $code
