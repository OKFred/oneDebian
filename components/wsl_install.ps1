# ==============================================================================
# components/wsl_install.ps1
# Description: 下载并导入 Debian rootfs 为 WSL 2 发行版 (带完整性校验与损坏缓存自动重下)
# Author: Fred
# ==============================================================================

param(
    [ValidateSet(12, 13)]
    [int]$Version = 13,

    [string]$DistroName = '',

    [string]$WslRoot = 'D:\wsl'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

if (-not $DistroName) {
    $DistroName = "Debian-$Version"
}

# 规范发行版名称 (过滤非合法字符)
$DistroName = ($DistroName -replace '[^a-zA-Z0-9._-]', '').Trim()
if (-not $DistroName) { $DistroName = "Debian-$Version" }

$suite = if ($Version -eq 12) { 'bookworm' } else { 'trixie' }
$archiveDir = Join-Path $WslRoot 'images'
$archivePath = Join-Path $archiveDir "debian-$Version-rootfs.tar.xz"
$installPath = Join-Path $WslRoot $DistroName
$imageDirectory = "https://images.linuxcontainers.org/images/debian/$suite/amd64/default/"

try {
    # 1. 检查目标发行版或安装路径是否已存在
    $existingDistros = @(Get-WslDistros)
    if ($existingDistros -contains $DistroName) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: WSL 发行版 '$DistroName' 已经存在！" } else { "Error: WSL distro '$DistroName' already exists!" })" -ForegroundColor Red
        Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '如需重新安装，请先在菜单中卸载或更名该发行版。' } else { 'Please uninstall or rename existing distro first.' })" -ForegroundColor Yellow
        return
    }

    if (Test-Path -LiteralPath $installPath) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 安装目录已存在 -> '$installPath'" } else { "Error: Install directory already exists -> '$installPath'" })" -ForegroundColor Red
        return
    }

    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

    # 2. 获取官网最新构建地址
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

    $cleanBuild = [System.Uri]::UnescapeDataString($rawBuilds[0])
    $imageUrl = "$imageDirectory$cleanBuild"
    $rootfsUrl = "${imageUrl}rootfs.tar.xz"

    # 获取校验和
    $checksums = (& curl.exe -fLs "${imageUrl}SHA256SUMS") -join "`n"
    $expectedHash = $null
    if ($LASTEXITCODE -eq 0 -and $checksums) {
        $checksumLine = $checksums -split "`r?`n" |
            Where-Object { $_ -match '\s\*?rootfs\.tar\.xz$' } |
            Select-Object -First 1
        if ($checksumLine) {
            $expectedHash = ($checksumLine -split '\s+')[0].ToUpperInvariant()
        }
    }

    # 3. 判断本地缓存是否完好
    $useCache = $false
    if (Test-Path -LiteralPath $archivePath) {
        if ($expectedHash) {
            $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($expectedHash -eq $actualHash) {
                $useCache = $true
            } else {
                Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '检测到本地缓存已被破坏或过期，准备重新下载干净镜像...' } else { 'Local cache invalid, redownloading...' })" -ForegroundColor Yellow
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            }
        } else {
            # 如果获取不到 SHA256，退回文件大小判断 (必须 > 20MB)
            if ((Get-Item -LiteralPath $archivePath).Length -gt 20MB) {
                $useCache = $true
            }
        }
    }

    # 4. 安装参数确认
    Write-Host "`n$(Get-I18nStr 'Install_Confirm_Title')" -ForegroundColor Yellow
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '自定义发行版名称' } else { 'Custom Distro Name' }): $DistroName" -ForegroundColor Cyan
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '目标安装目录' } else { 'Install Directory' }): $installPath" -ForegroundColor Cyan
    if ($useCache) {
        Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '镜像来源' } else { 'Image Source' }): [⚡ 完好本地缓存复用] ($archivePath)" -ForegroundColor Green
    } else {
        Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '镜像下载地址' } else { 'Image Download URL' }): $rootfsUrl" -ForegroundColor Gray
    }

    $confirm = Read-Host "`n$(Get-I18nStr 'Install_Confirm_Prompt') $DistroName? [Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
        return
    }

    # 5. 下载或复用
    if ($useCache) {
        Write-Host "`n[1/3] $(if ($global:CurrentLang -eq 'zh-CN') { "本地镜像缓存 Hash 校验通过，直接复用: $archivePath" } else { "Local cache verified, reusing: $archivePath" })" -ForegroundColor Green
    } else {
        Write-Host "`n[1/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在下载 Debian $Version 完整 rootfs 镜像..." } else { "Downloading Debian $Version rootfs..." })" -ForegroundColor Green
        & curl.exe -fL --retry 3 --retry-delay 2 -o "$archivePath" "$rootfsUrl"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 镜像下载失败 (Exit Code: $LASTEXITCODE)。" } else { "Error: Image download failed (Exit Code: $LASTEXITCODE)." })" -ForegroundColor Red
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            return
        }

        Write-Host "[2/3] $(if ($global:CurrentLang -eq 'zh-CN') { '正在校验 SHA-256 签名完整性...' } else { 'Verifying SHA-256 checksum...' })" -ForegroundColor Green
        if ($expectedHash) {
            $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($expectedHash -ne $actualHash) {
                Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '错误: SHA-256 哈希校验不匹配，下载镜像损坏。' } else { 'Error: SHA-256 verification failed.' })" -ForegroundColor Red
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                return
            }
        }
    }

    # 6. 导入为 WSL 发行版
    Write-Host "[3/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在导入 $DistroName 为 WSL 2 发行版..." } else { "Importing $DistroName as WSL 2 distro..." })" -ForegroundColor Green
    & wsl.exe --import $DistroName $installPath $archivePath --version 2
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: wsl --import 执行失败 (Exit Code: $LASTEXITCODE)。" } else { "Error: wsl --import failed (Exit Code: $LASTEXITCODE)." })" -ForegroundColor Red
        return
    }

    Write-Host "`n[✓] $(if ($global:CurrentLang -eq 'zh-CN') { '安装导入成功完成！' } else { 'Import complete successfully!' })" -ForegroundColor Green
    & wsl.exe --list --verbose
    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { 'Debian 系统版本信息:' } else { 'Debian Version Details:' })" -ForegroundColor Gray
    & wsl.exe --distribution $DistroName --user root -- cat /etc/debian_version

    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "启动该发行版命令: wsl -d $DistroName" } else { "To start distro run: wsl -d $DistroName" })" -ForegroundColor Yellow
} catch {
    Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "安装失败: $($_.Exception.Message)" } else { "Installation failed: $($_.Exception.Message)" })" -ForegroundColor Red
}
