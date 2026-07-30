# netbird-windows-scripts

Deploying the NetBird Windows client from an RMM, and getting the tray icon to
actually appear.

One script, `Install-NetBird.ps1`, with three phases. PowerShell 5.1 compatible,
no modules, no dependencies. Client v0.75.0 or later.

## The problem this exists to solve

A silent MSI install run as SYSTEM gives you a working tunnel and no tray icon.
Users can reach their resources, `netbird status` says Connected, and nothing in
the system tray. Opening NetBird from the Start Menu works immediately, which
makes the whole thing look like a cosmetic glitch.

It is not. There are two separate mechanisms behind it, and only one of them is
about your script:

**The tray UI cannot start outside an interactive user session.** The daemon is
a Windows service and installs and runs fine from SYSTEM. `netbird-ui.exe` is a
desktop application: it needs a window station on the signed-in user's desktop.
Started from a service or system context it exits with code 1 in about 90 ms,
having logged one line, and leaves no process behind. Nothing surfaces anywhere
a deploying admin would look. An RMM step labelled "run as current user" is not
always in that user's session, and an RMM that kills its script's process tree
on completion takes the tray with it either way.

**Launch at login is per-user from v0.75.0, and it is a one-time decision.** It
used to be an installer property writing a machine-wide `Run` entry. It is now
set by the tray UI itself, for that user, the first time it starts successfully,
once. Get that first launch right and the tray comes back at every subsequent
sign-in with no scripting at all. Get it wrong and there is no second chance for
that user.

So the deployment problem is a first-run problem, and it belongs in a phase that
runs as the user rather than as SYSTEM.

## Usage

### Phase 1: install, as SYSTEM or an elevated admin

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
  -File .\Install-NetBird.ps1 -Phase Install `
  -ManagementUrl https://api.example.com -Version 0.75.1
```

Writes the management server into managed policy, downloads the MSI for the
machine's architecture, verifies its Authenticode signature and publisher,
installs silently, and confirms the daemon service is running. Logs to
`%ProgramData%\NetBird\netbird-deploy.log`, with the msiexec verbose log
alongside it.

Omit `-ManagementUrl` for NetBird Cloud. Omit `-Version` to take the current
release, though pinning is worth the small extra effort for a fleet.

### Phase 2: provision, as the signed-in user, not elevated

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Install-NetBird.ps1 -Phase Provision
```

Refuses to run from session 0 and refuses to run elevated, because both produce
a device that silently never gets a tray icon. Registers the peer (interactive
SSO by default, or `-SetupKeyFile` for machines), launches the tray so that it
lands on the user's desktop and survives this script exiting, then verifies that
the tray is alive in the right session and that launch at login is set. Logs to
`%LOCALAPPDATA%\NetBird\netbird-provision.log`.

### Phase 3: check, anytime

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Install-NetBird.ps1 -Phase Check
```

Read-only. Prints identity, session, elevation, installed version, service
state, managed policy, daemon status, tray processes with their session IDs, and
the launch-at-login value. Run it as the affected user when a device reports no
tray icon: the first two lines usually answer it.

## How the tray gets launched

Not `Start-Process`. The provision phase registers a short-lived scheduled task
with an `Interactive` principal, starts it, and unregisters it:

```powershell
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
```

An `Interactive` principal reuses the logon token the signed-in user already
has, so the process always lands on their desktop, and the task is not a child
of the deployment script, so an RMM tearing down its process tree does not take
the tray with it. No password is stored and no administrative rights are needed.

`RunLevel Limited` is load-bearing rather than cautious. Launch at login is only
set when the tray's first successful start is unelevated, so an elevated first
launch costs that user their tray icon on every future sign-in, permanently,
with nothing logged.

## Parameters

| Parameter | Phase | Notes |
|---|---|---|
| `-Phase` | | `Install`, `Provision`, or `Check`. Default `Install`. |
| `-ManagementUrl` | Install, Provision | Self-hosted management server. Omit for NetBird Cloud. The port is optional: the client appends `:443` for https. |
| `-AdminUrl` | Provision | Dashboard URL, if it differs from the management URL. |
| `-Version` | Install | Pin a release, for example `0.75.1`. Omitted means the current release. |
| `-SetupKeyFile` | Provision | Path to a file holding a setup key. Omitted means interactive SSO. |
| `-SkipPolicy` | Install | Do not write `ManagementURL` into managed policy. |
| `-Force` | Install | Reinstall even when the requested version is already present. |
| `-AllowElevated` | Provision | Proceed from an elevated process, writing the launch-at-login value directly since the tray will not. |
| `-ConnectTimeoutSeconds` | Provision | Default 120. `netbird up` against an unreachable server blocks indefinitely rather than failing, so this is bounded. |
| `-Quiet` | | File-only logging, no console output. |
| `-LogPath` | | Override the log location. |

## Notes worth knowing

**The management URL goes in managed policy, not on a command line.** The
install phase writes `ManagementURL` under
`HKLM\Software\Policies\NetBird`, before msiexec runs, so the daemon's very
first config already points at the right server. This also avoids a trap: a
`ManagementURL` policy value silently overrides a `--management-url` passed on
the command line rather than rejecting it, so a script carrying both is not
broken but is also not in control of the value. The provision phase detects this
and says so.

**`AUTOSTART=0` does nothing on v0.75.x.** The MSI property existed through
v0.74.7 and wrote a machine-wide `Run` entry. On v0.75.x there is no such
property; passing it is accepted silently with exit code 0 and the string does
not appear in the verbose MSI log at all. Suppress the tray at login with the
`DisableAutostart` managed policy value instead, which is enforced on every UI
launch rather than once at install time.

**`Test-Path "C:\ProgramData\Netbird"` is not an install check.** That folder
appears because the daemon writes its config during the install, seconds after
the service starts and well before msiexec returns. It tells you the daemon ran,
not that the install completed. Check for the `NetBird` service in the `Running`
state, which is what the install phase does.

**Do not mix installer channels.** Running the NSIS `.exe` over an MSI install
upgrades `netbird-ui.exe` but leaves the running daemon binary at the old
version, because the service holds the file, and registers a second uninstall
entry. `netbird version` then reports the old version while the tray is new.
This script uses the MSI throughout. The check phase warns when it sees two
uninstall entries.

**ARM64 is handled.** Architecture is read from `PROCESSOR_ARCHITEW6432` before
`PROCESSOR_ARCHITECTURE`, because the latter reports `x86` when the RMM happens
to run a 32-bit PowerShell host on a 64-bit machine.

## Related

- [netbird-gpo-deployment](https://github.com/SunsetDrifter/netbird-gpo-deployment)
  covers the domain-joined case: ADMX templates, managed policy profiles, and
  GPO-driven deployment. Use that one if you have Active Directory and Group
  Policy. Use this one if you have an RMM.
- [NetBird Windows install docs](https://docs.netbird.io/get-started/install/windows)
- [MDM managed policy reference](https://docs.netbird.io/client/mdm-integration)

## Behavior claims

Every claim above about v0.75.x behavior was measured on Windows Server 2022
with client v0.75.1, against v0.74.7 as a version control, rather than read off
the source. The details are unremarkable and the conclusions are not, which is
why they are stated as flatly as they are.
