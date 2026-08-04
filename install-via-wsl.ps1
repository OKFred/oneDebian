param(
    [ValidateSet(12, 13)]
    [int]$Version = 13,

    [string]$WslRoot = 'D:\wsl'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$suite = if ($Version -eq 12) { 'bookworm' } else { 'trixie' }
$distroName = "Debian-$Version"
$archiveDir = Join-Path $WslRoot 'images'
$archivePath = Join-Path $archiveDir "debian-$Version-rootfs.tar.xz"
$installPath = Join-Path $WslRoot $distroName
$imageDirectory = "https://images.linuxcontainers.org/images/debian/$suite/amd64/default/"

# Do not overwrite an existing WSL distribution or its storage.
$existingDistros = @(
    & wsl.exe --list --quiet |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if ($existingDistros -contains $distroName) {
    throw "WSL distribution '$distroName' already exists."
}
if (Test-Path -LiteralPath $installPath) {
    throw "Install directory already exists: $installPath"
}

New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

# Select the newest published rootfs build for the requested Debian release.
$listing = (& curl.exe -fLs $imageDirectory) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Unable to download the image directory listing.' }

$builds = @(
    [regex]::Matches($listing, 'href="(?<build>\d{8}_\d{2}%3A\d{2}/)"') |
        ForEach-Object { $_.Groups['build'].Value } |
        Sort-Object -Descending
)
if ($builds.Count -eq 0) { throw "No amd64 rootfs build was found for Debian $Version." }

$imageUrl = "$imageDirectory$($builds[0])"
$rootfsUrl = "$imageUrl`rootfs.tar.xz"

Write-Host "Downloading Debian $Version rootfs..."
& curl.exe -fL --retry 3 --retry-delay 2 -o $archivePath $rootfsUrl
if ($LASTEXITCODE -ne 0) { throw "Download failed with exit code $LASTEXITCODE." }

Write-Host 'Verifying SHA-256...'
$checksums = (& curl.exe -fLs "$imageUrl`SHA256SUMS") -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Unable to download SHA256SUMS.' }

$checksumLine = $checksums -split "`r?`n" |
    Where-Object { $_ -match '\s\*?rootfs\.tar\.xz$' } |
    Select-Object -First 1
if (-not $checksumLine) { throw 'rootfs.tar.xz was not listed in SHA256SUMS.' }

$expected = ($checksumLine -split '\s+')[0].ToUpperInvariant()
$actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($expected -ne $actual) { throw 'SHA-256 verification failed; import was not started.' }

Write-Host "Importing $distroName as WSL 2..."
& wsl.exe --import $distroName $installPath $archivePath --version 2
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed with exit code $LASTEXITCODE." }

Write-Host "`nImport complete:"
& wsl.exe --list --verbose
Write-Host "`nDebian version:"
& wsl.exe --distribution $distroName --user root -- cat /etc/debian_version

Write-Host "`nTo run the specified distribution in the future (e.g. $distroName), simply run: wsl -d $distroName"



