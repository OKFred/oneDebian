# ==============================================================================
# components/wsl_install.ps1
# Description: 下载并导入 Debian rootfs 为 WSL 2 发行版
# ==============================================================================

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

try {
    # 检查目标发行版是否已存在
    $rawList = & wsl.exe --list --quiet 2>$null
    $existingDistros = @()
    if ($rawList) {
        $existingDistros = @(
            $rawList | ForEach-Object { $_ -replace "`0", "" } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        )
    }

    if ($existingDistros -contains $distroName) {
        Write-Host "`n[!] 错误: WSL 发行版 '$distroName' 已经存在！" -ForegroundColor Red
        Write-Host "    如需重新安装，请先在菜单中卸载或还原该发行版。" -ForegroundColor Yellow
        return
    }

    if (Test-Path -LiteralPath $installPath) {
        Write-Host "`n[!] 错误: 安装目录已存在 -> '$installPath'" -ForegroundColor Red
        Write-Host "    请选择其他安装目录或删除已有文件夹后重试。" -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

    Write-Host "正在获取 Debian $Version 官方镜像列表..." -ForegroundColor Green
    $listing = (& curl.exe -fLs $imageDirectory) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] 错误: 无法下载 Debian 镜像目录列表，请检查网络连接。" -ForegroundColor Red
        return
    }

    $builds = @(
        [regex]::Matches($listing, 'href="(?<build>\d{8}_\d{2}%3A\d{2}/)"') |
            ForEach-Object { $_.Groups['build'].Value } |
            Sort-Object -Descending
    )
    if ($builds.Count -eq 0) {
        Write-Host "`n[!] 错误: 未找到适用于 Debian $Version (amd64) 的 rootfs 构建镜像。" -ForegroundColor Red
        return
    }

    $imageUrl = "$imageDirectory$($builds[0])"
    $rootfsUrl = "$imageUrl`rootfs.tar.xz"

    Write-Host "`n[!] 安装参数确认:" -ForegroundColor Yellow
    Write-Host "    发行版名称: $distroName" -ForegroundColor Cyan
    Write-Host "    目标安装目录: $installPath" -ForegroundColor Cyan
    Write-Host "    镜像下载地址: $rootfsUrl" -ForegroundColor Gray

    $confirm = Read-Host "`n确认开始下载并安装 $distroName 吗？[Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    Write-Host "`n[1/3] 正在下载 Debian $Version rootfs..." -ForegroundColor Green
    & curl.exe -fL --retry 3 --retry-delay 2 -o $archivePath $rootfsUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] 错误: 镜像下载失败 (Exit Code: $LASTEXITCODE)。" -ForegroundColor Red
        return
    }

    Write-Host "[2/3] 正在校验 SHA-256 签名..." -ForegroundColor Green
    $checksums = (& curl.exe -fLs "$imageUrl`SHA256SUMS") -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] 错误: 无法获取 SHA256SUMS 校验文件。" -ForegroundColor Red
        return
    }

    $checksumLine = $checksums -split "`r?`n" |
        Where-Object { $_ -match '\s\*?rootfs\.tar\.xz$' } |
        Select-Object -First 1
    if (-not $checksumLine) {
        Write-Host "`n[!] 错误: 未在 SHA256SUMS 中查找到 rootfs.tar.xz。" -ForegroundColor Red
        return
    }

    $expected = ($checksumLine -split '\s+')[0].ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($expected -ne $actual) {
        Write-Host "`n[!] 错误: SHA-256 哈希校验失败！可能文件损坏或下载未完成。" -ForegroundColor Red
        return
    }

    Write-Host "[3/3] 正在导入 $distroName 为 WSL 2 发行版..." -ForegroundColor Green
    & wsl.exe --import $distroName $installPath $archivePath --version 2
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] 错误: wsl --import 执行失败 (Exit Code: $LASTEXITCODE)。" -ForegroundColor Red
        return
    }

    Write-Host "`n[✓] 安装导入完成:" -ForegroundColor Green
    & wsl.exe --list --verbose
    Write-Host "`nDebian 版本信息:" -ForegroundColor Gray
    & wsl.exe --distribution $distroName --user root -- cat /etc/debian_version

    Write-Host "`nTo run the specified distribution in the future (e.g. $distroName), simply run: wsl -d $distroName" -ForegroundColor Yellow
} catch {
    Write-Host "`n[!] 安装失败: $($_.Exception.Message)" -ForegroundColor Red
}
