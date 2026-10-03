#Requires -Version 5.1
<#
Installs the pinned tool versions this repository expects.

  winget            Helm, Flux, age, mkcert, OpenTofu (official packages, exact versions)
  GitHub releases   k3d and sops, which have no winget package: downloaded from the projects'
                    own releases and verified against the published SHA-256 checksums before
                    they are moved into place.

Re-running is safe: winget skips packages already at the pinned version, and the release
downloads are skipped when the executable is already present (use -Force to redownload).
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 redraws the progress bar for every buffer, which makes large downloads
# many times slower.
$ProgressPreference = 'SilentlyContinue'

$winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
if (-not (Test-Path $winget)) { $winget = 'winget' }

$packages = @(
    @{ Id = 'Helm.Helm';          Version = '4.3.0' },
    @{ Id = 'FluxCD.Flux';        Version = '2.9.5' },
    @{ Id = 'FiloSottile.age';    Version = '1.3.1' },
    @{ Id = 'FiloSottile.mkcert'; Version = '1.4.4' },
    @{ Id = 'OpenTofu.Tofu';      Version = '1.12.6' }
)

# 0x8A15002B: "package already installed" (winget's exit code for an idempotent re-run).
$alreadyInstalled = -1978335189

foreach ($p in $packages) {
    Write-Host "== $($p.Id) $($p.Version)"
    & $winget install --id $p.Id --exact --version $p.Version --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $alreadyInstalled) {
        throw "winget failed for $($p.Id) (exit code $LASTEXITCODE)"
    }
}

$bin = Join-Path $env:LOCALAPPDATA 'Programs\lab-tools\bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

function Install-Release([string]$Repo, [string]$Tag, [string]$Asset, [string]$ChecksumAsset, [string]$Target) {
    $dest = Join-Path $bin $Target
    if ((Test-Path $dest) -and -not $Force) { Write-Host "== $Target already present ($dest)"; return }
    $base = "https://github.com/$Repo/releases/download/$Tag"
    $tmp = Join-Path $env:TEMP $Asset
    Write-Host "== downloading $Asset from $Repo $Tag"
    Invoke-WebRequest -Uri "$base/$Asset" -OutFile $tmp -UseBasicParsing
    # GitHub serves the checksum file as application/octet-stream, so .Content would be bytes;
    # save it and read it as text instead.
    $sumsFile = Join-Path $env:TEMP $ChecksumAsset
    Invoke-WebRequest -Uri "$base/$ChecksumAsset" -OutFile $sumsFile -UseBasicParsing
    $sums = Get-Content -Path $sumsFile -Raw
    # Checksum lines look like "<sha256>  <name>", where the name may carry a path prefix
    # (k3d writes "_dist/<name>") or a binary-mode marker ("*<name>").
    $line = ($sums -split "`n" | Where-Object { $_ -match ('(^|[\s/*])' + [regex]::Escape($Asset) + '\s*$') } | Select-Object -First 1)
    if (-not $line) { Remove-Item $tmp; throw "no checksum for $Asset in $ChecksumAsset" }
    $expected = ($line.Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Remove-Item $tmp; throw "checksum mismatch for $Asset (expected $expected, got $actual)" }
    Move-Item -Force -Path $tmp -Destination $dest
    Write-Host "== $Target $Tag verified (sha256 $expected) and installed to $dest"
}

Install-Release -Repo 'k3d-io/k3d'   -Tag 'v5.9.0'  -Asset 'k3d-windows-amd64.exe'   -ChecksumAsset 'checksums.txt'                -Target 'k3d.exe'
Install-Release -Repo 'getsops/sops' -Tag 'v3.13.3' -Asset 'sops-v3.13.3.amd64.exe' -ChecksumAsset 'sops-v3.13.3.checksums.txt' -Target 'sops.exe'

# The user-level PATH may not exist yet on a fresh profile; treat it as empty rather than null.
$userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $bin) {
    $newPath = if ($userPath.Trim()) { $userPath.TrimEnd(';') + ';' + $bin } else { $bin }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "== added $bin to the user PATH; open a new shell to pick it up"
}

Write-Host "== done"
