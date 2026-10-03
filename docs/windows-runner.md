# A self-hosted Windows runner, and what GitHub's images hide

GitHub's hosted Windows runners are fresh virtual machines with one user and a long list of tools
already installed. A runner on your own Windows machine has only what you installed, and the
defaults Windows ships with. Each of the problems below stopped a job on a real machine before
[`runners/windows/install-runner.ps1`](../runners/windows/install-runner.ps1) handled it.

## 1. The Windows runner reads `.env`, not `.path`

The runner's Linux and macOS start scripts read a `.path` file in the runner folder. The Windows
service never does: `Runner.Listener` loads `.env` when it starts (`KEY=value` lines) and nothing
else. A PATH written to `.path` is ignored, silently. The script writes `PATH=...` to `.env`.

## 2. `bash` on the machine PATH is WSL's launcher

`C:\Windows\System32\bash.exe` starts the Windows Subsystem for Linux, and System32 comes before Git
in the machine PATH. A `shell: bash` step then runs in Linux, or fails with "Windows Subsystem for
Linux has no installed distributions". The script puts `C:\Program Files\Git\bin` first.

## 3. A step without `shell:` gets Windows PowerShell 5.1

On Windows, a `run:` step defaults to PowerShell. GitHub's images ship PowerShell 7; your machine
may have only Windows PowerShell 5.1, whose default execution policy (Restricted) refuses the
script file the runner writes for each step: "running scripts is disabled on this system".
Set the shell in the workflow instead of loosening the machine:

```yaml
jobs:
  test:
    defaults:
      run:
        shell: bash
```

## 4. A folder under `C:\` is writable by every user

`C:\actions-runners` inherits the drive root's "Authenticated Users: Modify". The runner folder holds
`.credentials` (the runner's key to GitHub) and the programs the service runs, so any local process
could read the key or replace the programs. The script removes inheritance, grants Administrators,
SYSTEM, `NETWORK SERVICE` and the runner's service group, and resets everything below to inherit.

Two traps on the way, both of which `icacls` reports as success:

- Granting folder-style permissions file by file (`/grant:r ... (OI)(CI)F /T`) after removing
  inheritance leaves every file with an **empty** permission list: inheritance flags on a file are
  dropped. The service then cannot start ("Access is denied"). Lock the folder, then
  `icacls <folder>\* /reset /T`.
- An administrator cannot reset a file it does not own, and the files the service created
  (`_work`) are owned by `NETWORK SERVICE`. Take ownership first (`takeown /a /r`), then hand
  `_work` back to `NETWORK SERVICE` afterwards: git refuses a checkout owned by another account
  ("dubious ownership"), which `go build` reports as "error obtaining VCS status".

`icacls /C` keeps going past files it cannot change and can still exit 0, so the script reads its
summary line ("Failed processing 0 files") instead of trusting the exit code.

## 5. Windows shortens long service names

`config.cmd --runasservice` names the service `actions.runner.<owner>-<repo>.<runner name>`, and
when that exceeds 80 characters on Windows it shortens the owner-and-repo part and the runner part
and appends a random number: `lab-windows-shci-smoke-windows-<host>` became
`lab-windows-shci-smoke-win-2747`. It records the name it chose, as plain text, in the runner
folder's `.service` file (`WindowsServiceControlManager` in the runner's source); look the service up
by that, never by rebuilding the name. A short name hides this: the first longer one fails.

## What the script does

1. Refuses unless GitHub reports the repository as private.
2. Downloads the pinned runner release and checks its SHA-256.
3. Registers the runner (label `lab-windows`) with a one-hour token from `gh`, never printed, and
   installs it as a service running as `NT AUTHORITY\NETWORK SERVICE`: no account, no password.
4. Locks the runner folder (section 4).
5. Writes PATH to `.env` with Git Bash first (sections 1 and 2) and starts the service.

Running it again on an installed runner repeats steps 4 and 5, so it also repairs an install made
by an earlier version. `-Remove` unregisters the runner and deletes the folder.

The jobs still run on your desktop, not in a container. That is why this runner serves private
repositories only, for merged code only. When that is not enough, put the same runner inside a
Windows virtual machine: the script and the workflow switch do not change.
