# ==============================================================================
# components/wsl_install.ps1
# Description: 下载并导入 Debian rootfs 为 WSL 2 发行版 (100% 全量双语 i18n 兼容)
# Author: Fred
# ==============================================================================

param(
    [ValidateSet(12, 13)]
    [int]$Version = 13,

    [string]$WslRoot = 'D:\wsl'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

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
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: WSL 发行版 '$distroName' 已经存在！" } else { "Error: WSL distro '$distroName' already exists!" })" -ForegroundColor Red
        return
    }

    if (Test-Path -LiteralPath $installPath) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 安装目录已存在 -> '$installPath'" } else { "Error: Install directory already exists -> '$installPath'" })" -ForegroundColor Red
        return
    }

    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

    Write-Host "$(if ($global:CurrentLang -eq 'zh-CN') { "正在获取 Debian $Version 官方镜像列表..." } else { "Fetching Debian $Version official image list..." })" -ForegroundColor Green
    $listing = (& curl.exe -fLs $imageDirectory) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '错误: 无法下载 Debian 镜像目录列表，请检查网络连接。' } else { 'Error: Failed to fetch image list, check network.' })" -ForegroundColor Red
        return
    }

    $rawBuilds = @(
        [regex]::Matches($listing, 'href="(?<build>\d{8}[^"]+/)"') |
            ForEach-Object { $_.Groups['build'].Value } |
            Sort-Object -Descending
    )
    if ($rawBuilds.Count -eq 0) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 未找到适用于 Debian $Version (amd64) 的 rootfs 镜像。" } else { "Error: No rootfs image found for Debian $Version (amd64)." })" -ForegroundColor Red
        return
    }

    # URL 解码 %3A 为标准的冒号 :，防止 curl.exe (Exit Code 3) 报错
    $cleanBuild = [System.Uri]::UnescapeDataString($rawBuilds[0])
    $imageUrl = "$imageDirectory$cleanBuild"
    $rootfsUrl = "${imageUrl}rootfs.tar.xz"

    Write-Host "`n$(Get-I18nStr 'Install_Confirm_Title')" -ForegroundColor Yellow
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '发行版名称' } else { 'Distro Name' }): $distroName" -ForegroundColor Cyan
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '目标安装目录' } else { 'Install Directory' }): $installPath" -ForegroundColor Cyan
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '镜像下载地址' } else { 'Image Download URL' }): $rootfsUrl" -ForegroundColor Gray


    $confirm = Read-Host "`n$(Get-I18nStr 'Install_Confirm_Prompt') $distroName? [Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
        return
    }

    Write-Host "`n[1/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在下载 Debian $Version rootfs..." } else { "Downloading Debian $Version rootfs..." })" -ForegroundColor Green
    & curl.exe -fL --retry 3 --retry-delay 2 -o "$archivePath" "$rootfsUrl"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 镜像下载失败 (Exit Code: $LASTEXITCODE)。" } else { "Error: Image download failed (Exit Code: $LASTEXITCODE)." })" -ForegroundColor Red
        return
    }

    Write-Host "[2/3] $(if ($global:CurrentLang -eq 'zh-CN') { '正在校验 SHA-256 签名...' } else { 'Verifying SHA-256 checksum...' })" -ForegroundColor Green
    $checksums = (& curl.exe -fLs "${imageUrl}SHA256SUMS") -join "`n"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '错误: 无法获取 SHA256SUMS 校验文件。' } else { 'Error: Failed to fetch SHA256SUMS file.' })" -ForegroundColor Red
        return
    }

    $checksumLine = $checksums -split "`r?`n" |
        Where-Object { $_ -match '\s\*?rootfs\.tar\.xz$' } |
        Select-Object -First 1
    if (-not $checksumLine) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '错误: 未在 SHA256SUMS 中查找到 rootfs.tar.xz。' } else { 'Error: rootfs.tar.xz not found in SHA256SUMS.' })" -ForegroundColor Red
        return
    }

    $expected = ($checksumLine -split '\s+')[0].ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($expected -ne $actual) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '错误: SHA-256 哈希校验失败！文件可能损坏。' } else { 'Error: SHA-256 verification failed! File corrupted.' })" -ForegroundColor Red
        return
    }

    Write-Host "[3/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在导入 $distroName 为 WSL 2 发行版..." } else { "Importing $distroName as WSL 2 distro..." })" -ForegroundColor Green
    & wsl.exe --import $distroName $installPath $archivePath --version 2
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: wsl --import 执行失败 (Exit Code: $LASTEXITCODE)。" } else { "Error: wsl --import failed (Exit Code: $LASTEXITCODE)." })" -ForegroundColor Red
        return
    }

    Write-Host "`n[✓] $(if ($global:CurrentLang -eq 'zh-CN') { '安装导入完成:' } else { 'Import complete:' })" -ForegroundColor Green
    & wsl.exe --list --verbose
    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { 'Debian 版本信息:' } else { 'Debian Version Details:' })" -ForegroundColor Gray
    & wsl.exe --distribution $distroName --user root -- cat /etc/debian_version

    Write-Host "`nTo run the specified distribution in the future (e.g. $distroName), simply run: wsl -d $distroName" -ForegroundColor Yellow
} catch {
    Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "安装失败: $($_.Exception.Message)" } else { "Installation failed: $($_.Exception.Message)" })" -ForegroundColor Red
}
