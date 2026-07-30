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
  -ManagementUrl https://api.example.com
```

Add `-Version 0.75.1` only if the fleet has to stay on a specific release.

Writes the management server into managed policy, downloads the current
release for the machine's architecture, verifies its Authenticode signature and
publisher, installs silently, and confirms the daemon service is running. Logs
to `%ProgramData%\NetBird\netbird-deploy.log`, with the msiexec verbose log
alongside it.

Omit `-ManagementUrl` for NetBird Cloud. `-Version` is optional: without it you
get the current release, which is what most deployments want. Pass one only to
hold a fleet at a known version. Either way the installed version is written to
the log, so a machine's log records what it actually got.

If NetBird is already installed the phase does nothing, so an RMM can re-run it
freely. It does not silently upgrade a fleet on every pass; `-Force` upgrades or
reinstalls when you actually mean to.

### Phase 2: provision, as the signed-in user, not elevated

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
  -File .\Install-NetBird.ps1 -Phase Provision
```

Refuses to run from session 0 and refuses to run elevated, because both produce
a device that silently never gets a tray icon. Then, in this order: launches the
tray so that it lands on the user's desktop and survives this script exiting,
confirms it is alive in the right session, registers the peer (interactive SSO by
default, or `-SetupKeyFile` for machines), and checks that launch at login is
set. Logs to `%LOCALAPPDATA%\NetBird\netbird-provision.log`.

The tray goes first on purpose. Registration can take a while and can fail: with
interactive SSO it waits on a person, and against an unreachable server it blocks
until the timeout. Connecting first would leave the user with no tray at all for
up to five minutes on exactly the paths where they most need one, and the tray is
itself one of the ways to complete a sign-in.

That does not create two competing login flows. Measured on v0.76.0 with the
daemon in `NeedsLogin`: the tray launched on its own opens no browser and
triggers no login attempt in the daemon log, and stays in `NeedsLogin`. It waits
for the user rather than starting a flow. Running `netbird up` afterwards logs
exactly one login attempt and opens one browser, with the tray running
throughout.

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
| `-Version` | Install | Hold at a specific release, for example `0.75.1`. Omitted, the default, installs the current release. |
| `-SetupKeyFile` | Provision | Path to a file holding a setup key. Omitted means interactive SSO. |
| `-SkipPolicy` | Install | Do not write `ManagementURL` into managed policy. |
| `-Force` | Install | Reinstall even when the requested version is already present. |
| `-AllowElevated` | Provision | Proceed from an elevated process, writing the launch-at-login value directly since the tray will not. |
| `-ConnectTimeoutSeconds` | Provision | Default 300, generous enough for a human to complete an interactive sign-in. `netbird up` against an unreachable server blocks indefinitely rather than failing, so this is bounded. |
| `-Quiet` | | File-only logging, no console output. |
| `-LogPath` | | Override the log location. |

## Administrator rights

Only the install phase needs them, and only because it is silent.

| Phase | Needs admin |
|---|---|
| `Install` | yes, SYSTEM or an already-elevated process |
| `Provision` | **no**, and it refuses to run elevated |
| `Check` | no |

You may be told the NetBird installer does not need administrator rights. Run
interactively that is true: the MSI requests elevation itself and Windows shows
a UAC prompt, so nobody has to right-click and choose "Run as administrator".

A silent install cannot do that. With `/qn` there is no UI, so Windows will not
show the prompt and refuses outright. Measured on Windows Server 2022 with
v0.76.0, as a genuine standard user (`Users` only, not `Administrators`):

```
exit=1625
MSI (s) MSI_LUA: Installation UI level is silent, no credential elevation is possible
```

The same MSI run interactively by the same user produced a `consent.exe` UAC
credential prompt, which is the elevation request the dev is describing. Both
things are true at once; only one of them applies to an RMM. The install is
per-machine either way: `Program Files`, a Windows service, and a system `PATH`
entry.

The provision phase is the opposite case and it matters more, because it runs on
every user device. It needs no administrator rights at all: registering a
scheduled task with an `Interactive` principal is something a standard user may
do for themselves, `netbird up` talks to the already-running daemon over its
local socket, and the launch-at-login value lives in `HKCU`. Verified end to end
as an account in `Users` and nothing else.

## On staying silent

The install phase is silent in every sense. `msiexec` runs `/qn /norestart` with
no UI, it is started `-WindowStyle Hidden`, and the phase runs as SYSTEM in
session 0, where there is no user desktop to draw on. Nothing can appear no
matter how it is launched.

The provision phase is different, and the difference is not optional: it runs in
the user's own session, because that is the only place the tray can start. So
whether the user sees anything depends on how your RMM launches it, not on what
the script does. Measured on Windows Server 2022, launching through a scheduled
task with an `Interactive` principal:

| Launch | Visible console on the user's desktop |
|---|---|
| `powershell.exe -File ...` | yes |
| `powershell.exe -WindowStyle Hidden -File ...` | no |

Pass `-WindowStyle Hidden` on the provision step. `-Quiet` is a different knob:
it suppresses the script's own console output, and stops nothing from being
drawn.

The tray launch itself never shows a console. `netbird-ui.exe` is a GUI
application started directly by the scheduled task, and `netbird up` runs with
`-NoNewWindow`, so it borrows the caller's console rather than opening one.

## Notes worth knowing

**The management URL goes in managed policy, not on a command line.** The
install phase writes `ManagementURL` under
`HKLM\Software\Policies\NetBird`, before msiexec runs, so the daemon's very
first config already points at the right server. This also avoids a trap: a
`ManagementURL` policy value silently overrides a `--management-url` passed on
the command line rather than rejecting it, so a script carrying both is not
broken but is also not in control of the value. The provision phase detects this
and says so.

**`AUTOSTART=0` does nothing from v0.75.0 on.** The MSI property existed
through v0.74.7 and wrote a machine-wide `Run` entry. From v0.75.0 there is no
such property; passing it is accepted silently with exit code 0 and the string does
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

Every claim above was measured on Windows Server 2022 with client v0.75.1,
against v0.74.7 as a version control, rather than read off the source. The
details are unremarkable and the conclusions are not, which is why they are
stated as flatly as they are.

The claims still hold on v0.76.0: `client/ui/autostart_default.go`,
`client/netbird.wxs` and `client/installer.nsis` are byte-identical between
v0.75.1 and v0.76.0, so nothing the autostart and installer behavior rests on
changed. The script itself was run end to end on v0.76.0.
