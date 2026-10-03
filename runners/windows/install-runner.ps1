#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Installs GitHub's Actions runner on this machine as a Windows service for one private repository:
the Windows CI jobs that the cluster cannot run, because its nodes are Linux.

  .\install-runner.ps1 -Owner <owner> -Repo <repo>           install and register
  .\install-runner.ps1 -Owner <owner> -Repo <repo> -Remove   unregister and delete the runner

What it does, in order:
  1. Refuses unless GitHub reports the repository as private. Jobs on this runner run directly on
     this machine with no container around them; a public repository's pull requests come from anyone.
  2. Downloads the pinned runner release and checks its SHA-256 before unpacking it.
  3. Asks GitHub for a one-hour registration token through `gh` (your login), registers the
     runner with the label lab-windows, and installs it as a service running as
     NT AUTHORITY\NETWORK SERVICE: no user account, no password stored anywhere.
  4. Restricts the runner folder to Administrators, SYSTEM and the runner's service group: it holds
     the runner's credentials, and under C:\ it would inherit "Authenticated Users: Modify".
  5. Writes PATH into the runner's .env with Git for Windows' bash ahead of System32, so
     `shell: bash` steps get Git Bash and not WSL's bash.exe, and restarts the service.

Running it again on an installed runner skips the download and the registration and repeats steps
4 and 5, so it also repairs an install made by an earlier version of this script.

Run it from an elevated PowerShell (installing a service needs it), as your own user, so `gh` is
logged in. The repository's workflow sends a job here only when its CI_RUNNER_WINDOWS variable is
set (tofu/, windows_repos); until then this runner sits idle.

The runner keeps itself up to date: GitHub stops sending jobs to runners that fall too far
behind, so the pinned version below is only the one installed first.
#>
param(
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repo,
    [string]$Root = 'C:\actions-runners',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '2.337.0'
$Sha256 = '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc'
$Label = 'lab-windows'
$GitBin = 'C:\Program Files\Git\bin'

$dir = Join-Path $Root $Repo
$name = "lab-windows-$Repo-$($env:COMPUTERNAME.ToLower())"

function Invoke-Gh([string[]]$GhArgs) {
    $out = & gh @GhArgs
    if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs[0..1] -join ' ') failed (exit code $LASTEXITCODE)" }
    return $out
}

function Invoke-Config([string[]]$ConfigArgs) {
    Push-Location $dir
    try {
        & .\config.cmd @ConfigArgs
        if ($LASTEXITCODE -ne 0) { throw "config.cmd $($ConfigArgs[0]) failed (exit code $LASTEXITCODE)" }
    } finally { Pop-Location }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh is not on PATH; it requests the registration token' }

if ($Remove) {
    if (-not (Test-Path (Join-Path $dir '.runner'))) { Write-Host "no registered runner in $dir"; return }
    $token = Invoke-Gh @('api', '-X', 'POST', "repos/$Owner/$Repo/actions/runners/remove-token", '--jq', '.token')
    Invoke-Config @('remove', '--token', $token)
    Remove-Item -Recurse -Force $dir
    Write-Host "== removed $name and $dir"
    return
}

$private = Invoke-Gh @('api', "repos/$Owner/$Repo", '--jq', '.private')
if ($private -ne 'true') {
    throw "$Owner/$Repo is not private. A runner on this machine must never serve a public repository."
}
if (-not (Test-Path (Join-Path $GitBin 'bash.exe'))) {
    throw "Git for Windows' bash.exe is not in $GitBin; the workflows' bash steps need it."
}

if (-not (Test-Path (Join-Path $dir 'config.cmd'))) {
    $asset = "actions-runner-win-x64-$Version.zip"
    $zip = Join-Path $env:TEMP $asset
    Write-Host "== downloading $asset"
    Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$Version/$asset" -OutFile $zip -UseBasicParsing
    $got = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $Sha256) {
        Remove-Item $zip
        throw "checksum mismatch for $asset`n  expected $Sha256`n  got      $got"
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip
    Write-Host "== unpacked into $dir (SHA-256 verified)"
}

if (Test-Path (Join-Path $dir '.runner')) {
    Write-Host "== $dir is already registered; run with -Remove first to register it again"
} else {
    # The token is single-use, valid for an hour, and never printed.
    $token = Invoke-Gh @('api', '-X', 'POST', "repos/$Owner/$Repo/actions/runners/registration-token", '--jq', '.token')
    # --runasservice without --windowslogonaccount runs the service as NETWORK SERVICE and grants
    # that account access to this folder.
    Invoke-Config @('--unattended', '--url', "https://github.com/$Owner/$Repo", '--token', $token,
        '--name', $name, '--labels', $Label, '--work', '_work', '--runasservice', '--replace')
}

# The service's name comes from the .service file config.cmd writes. Windows limits service names,
# so config.cmd shortens a long runner name (lab-windows-<long repo>-<host> becomes, for example,
# lab-windows-<repo>-win-2747); rebuilding the name here would miss it.
$serviceFile = Join-Path $dir '.service'
if (-not (Test-Path $serviceFile)) { throw "$serviceFile is missing: config.cmd did not install a service" }
$serviceName = (Get-Content -Path $serviceFile -Raw).Trim()
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $service) { throw "no service named $serviceName (from $serviceFile) is installed" }
# Stopped while its files' permissions change, so no job is half-way through _work meanwhile.
Stop-Service -InputObject $service

# Administrators take ownership of everything first. Files the service created (its _work folder:
# checkouts, the tool cache) are owned by NETWORK SERVICE, and an administrator cannot reset the
# permissions of a file it does not own; the service keeps its access through the entries below.
& takeown /f $dir /a /r /d y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "takeown failed on $dir (exit code $LASTEXITCODE)" }

# Only administrators, SYSTEM and the runner's own service group may touch this folder. It holds
# .credentials (the runner's key to GitHub) and the programs the service runs, and a folder under
# C:\ otherwise inherits "Authenticated Users: Modify" from the drive root.
$acl = Get-Acl $dir
$runnerGroup = ($acl.Access | Where-Object { $_.IdentityReference.Value -like '*\GITHUB_ActionsRunner_*' } |
    Select-Object -First 1).IdentityReference.Value
if (-not $runnerGroup) { throw "the runner's GITHUB_ActionsRunner_* group has no entry on $dir; config.cmd did not finish" }
# Two steps: lock the folder itself (no inheritance from C:\, only these entries, passed down to
# everything below), then reset everything below so it inherits from it and nothing else. Granting
# per file with /T instead left the files with no usable entry and the service could not start.
# NETWORK SERVICE (S-1-5-20) is the service's account; it is named as well as its group.
& icacls $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-20:(OI)(CI)F' "${runnerGroup}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $dir (exit code $LASTEXITCODE)" }
# /C carries on past a file it cannot change and can still exit 0, so read its summary line too.
$summary = (& icacls (Join-Path $dir '*') /reset /T /C 2>&1 | Select-Object -Last 1) -as [string]
if ($LASTEXITCODE -ne 0 -or $summary -notmatch 'Failed processing 0 files') {
    throw "icacls /reset could not reset everything below $dir (exit code $LASTEXITCODE): $summary"
}
# The job workspace goes back to the service's account: git refuses a repository owned by another
# account ("dubious ownership", which go build reports as "error obtaining VCS status"), and the
# checkout in _work is reused from run to run.
$work = Join-Path $dir '_work'
if (Test-Path $work) {
    $summary = (& icacls $work /setowner '*S-1-5-20' /T /C 2>&1 | Select-Object -Last 1) -as [string]
    if ($LASTEXITCODE -ne 0 -or $summary -notmatch 'Failed processing 0 files') {
        throw "could not give $work back to NETWORK SERVICE (exit code $LASTEXITCODE): $summary"
    }
}

# Read the result back from a file the service must run and, when jobs have run, one it writes.
$probes = @((Join-Path $dir 'bin\RunnerService.exe')) + @(Get-ChildItem (Join-Path $dir '_work') -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
foreach ($probe in $probes) {
    $entries = (Get-Acl $probe).Access | ForEach-Object { $_.IdentityReference.Value }
    if (-not ($entries -match 'NETWORK SERVICE')) { throw "$probe does not grant NETWORK SERVICE access after the reset: $($entries -join ', ')" }
}
Write-Host "== $dir restricted to Administrators, SYSTEM, NETWORK SERVICE and $runnerGroup"

# The Windows runner reads .env when it starts (Runner.Listener's LoadAndSetEnv); .path is only
# read by the Linux and macOS start scripts. Git Bash goes first so `bash` is never System32's WSL
# launcher.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
Set-Content -Path (Join-Path $dir '.env') -Value "PATH=$GitBin;$machinePath" -Encoding ASCII
Remove-Item -Path (Join-Path $dir '.path') -ErrorAction SilentlyContinue
Start-Service -InputObject $service
Write-Host "== service $($service.Name) started with Git Bash first on its PATH"

Start-Sleep -Seconds 10
# Filtered here rather than with --jq: Windows PowerShell 5.1 drops the inner double quotes of an
# argument passed to a native program, so a jq string literal arrives as bare words.
$runners = (Invoke-Gh @('api', "repos/$Owner/$Repo/actions/runners")) -join "`n" | ConvertFrom-Json
$state = ($runners.runners | Where-Object { $_.name -eq $name }).status
Write-Host "== GitHub sees $name as: $state"
if ($state -ne 'online') { Write-Warning "not online yet; check the service and $dir\_diag" }
