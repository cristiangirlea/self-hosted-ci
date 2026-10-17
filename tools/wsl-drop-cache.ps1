# Drops the page cache of the Docker Desktop VM so WSL hands that memory back to Windows, which
# counts the cache as used. Run every 15 minutes by the task `make wsl-cache-task` registers.
param([string]$Distro = 'docker-desktop')

# wsl.exe prints UTF-16 unless told otherwise.
$env:WSL_UTF8 = '1'
$running = @(wsl.exe --list --running --quiet 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() }
# Any wsl.exe -d call starts a stopped distribution: never wake WSL just to empty its cache.
if ($running -notcontains $Distro) { exit 0 }

wsl.exe -d $Distro -u root -e sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'
exit $LASTEXITCODE
