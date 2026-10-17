# Registers (or with -Remove, unregisters) a scheduled task for the current user that runs
# wsl-drop-cache.ps1 from this folder every $Minutes minutes. `make wsl-cache-task` runs this.
param(
    [switch]$Remove,
    [ValidateRange(5, 1440)][int]$Minutes = 15,
    [string]$TaskName = 'self-hosted-ci WSL cache drop'
)

$name = $TaskName
if ($Remove) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host "removed scheduled task '$name'"
    } else {
        Write-Host "no scheduled task '$name'"
    }
    return
}

$script = Join-Path $PSScriptRoot 'wsl-drop-cache.ps1'
if (-not (Test-Path $script)) { throw "$script is missing" }
# conhost --headless runs PowerShell without a console window, so nothing flashes on screen.
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
    -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$null = Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force `
    -Description "Drops the Docker Desktop WSL VM's page cache every $Minutes minutes (self-hosted-ci, tools/wsl-drop-cache.ps1)."
Write-Host "registered scheduled task '$name': every $Minutes minutes, runs $script"
